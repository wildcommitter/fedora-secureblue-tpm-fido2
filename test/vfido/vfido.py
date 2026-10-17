#!/usr/bin/env python3
"""Virtual FIDO2 (CTAP2.1) authenticator behind a Linux USB HID gadget.

Test fixture only. Speaks CTAPHID on /dev/hidgN (see gadget.sh) and
implements just what systemd-cryptenroll / systemd-cryptsetup / libfido2
need for LUKS: getInfo, makeCredential, getAssertion with hmac-secret,
clientPIN (PIN/UV auth protocols 1 and 2) and reset. Credentials are
non-resident; state persists in a JSON file like a real token.

User presence ("touch") is scriptable through a control directory:
  <ctl>/presence   "auto" (default) | "deny" | "manual"
  <ctl>/touch      created by the test in manual mode; consumed per touch
Every event is logged as one line on stdout (EVENT key=value ...), which
the e2e test greps (e.g. EVENT up=granted).
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import select
import struct
import sys
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from fido2 import cbor

# CTAPHID
CMD_PING, CMD_MSG, CMD_LOCK, CMD_INIT, CMD_WINK = 0x01, 0x03, 0x04, 0x06, 0x08
CMD_CBOR, CMD_CANCEL, CMD_KEEPALIVE, CMD_ERROR = 0x10, 0x11, 0x3B, 0x3F
CAP_WINK, CAP_CBOR, CAP_NMSG = 0x01, 0x04, 0x08
BROADCAST = 0xFFFFFFFF
ERR_INVALID_CMD, ERR_INVALID_LEN, ERR_INVALID_SEQ, ERR_CHANNEL_BUSY = 0x01, 0x03, 0x04, 0x06

# CTAP2 status codes
OK = 0x00
INVALID_COMMAND = 0x01
INVALID_PARAMETER = 0x02
INVALID_CBOR = 0x12
MISSING_PARAMETER = 0x14
UNSUPPORTED_ALGORITHM = 0x26
OPERATION_DENIED = 0x27
UNSUPPORTED_OPTION = 0x2B
KEEPALIVE_CANCEL = 0x2D
NO_CREDENTIALS = 0x2E
USER_ACTION_TIMEOUT = 0x2F
PIN_INVALID = 0x31
PIN_BLOCKED = 0x32
PIN_AUTH_INVALID = 0x33
PIN_AUTH_BLOCKED = 0x34
PIN_NOT_SET = 0x35
PIN_REQUIRED = 0x36
PIN_POLICY_VIOLATION = 0x37

FLAG_UP, FLAG_UV, FLAG_AT, FLAG_ED = 0x01, 0x04, 0x40, 0x80
AAGUID = bytes.fromhex("7666696f2d6c756b732d746f6b656e21")  # "vfio-luks-token!"
PIN_RETRIES = 8
PRESENCE_TIMEOUT = 30.0


class CtapError(Exception):
    def __init__(self, code):
        self.code = code


def log(**kv):
    print("EVENT " + " ".join(f"{k}={v}" for k, v in kv.items()), flush=True)


def b64(b):
    return base64.b64encode(b).decode()


def unb64(s):
    return base64.b64decode(s)


def cose_p256(pub, alg):
    n = pub.public_numbers()
    return {1: 2, 3: alg, -1: 1, -2: n.x.to_bytes(32, "big"), -3: n.y.to_bytes(32, "big")}


def pub_from_cose(c):
    if c.get(1) != 2 or c.get(-1) != 1:
        raise CtapError(INVALID_PARAMETER)
    x = int.from_bytes(c[-2], "big")
    y = int.from_bytes(c[-3], "big")
    return ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()


def aes_cbc(key, iv, data, enc):
    c = Cipher(algorithms.AES(key), modes.CBC(iv))
    op = c.encryptor() if enc else c.decryptor()
    return op.update(data) + op.finalize()


class PinProtocol:
    """CTAP2 PIN/UV auth protocol 1 or 2 bound to one ECDH shared secret."""

    def __init__(self, version, agreement_key, peer_cose):
        self.v = version
        z = agreement_key.exchange(ec.ECDH(), pub_from_cose(peer_cose))
        if version == 1:
            self.hmac_key = self.aes_key = hashlib.sha256(z).digest()
        else:
            def kdf(info):
                return HKDF(hashes.SHA256(), 32, b"\x00" * 32, info).derive(z)
            self.hmac_key = kdf(b"CTAP2 HMAC key")
            self.aes_key = kdf(b"CTAP2 AES key")

    def encrypt(self, data):
        if self.v == 1:
            return aes_cbc(self.aes_key, b"\x00" * 16, data, True)
        iv = os.urandom(16)
        return iv + aes_cbc(self.aes_key, iv, data, True)

    def decrypt(self, data):
        if self.v == 1:
            if len(data) % 16:
                raise CtapError(INVALID_PARAMETER)
            return aes_cbc(self.aes_key, b"\x00" * 16, data, False)
        if len(data) < 32 or len(data) % 16:
            raise CtapError(INVALID_PARAMETER)
        return aes_cbc(self.aes_key, data[:16], data[16:], False)

    def verify(self, msg, sig):
        return verify_token(self.v, self.hmac_key, msg, sig)


def verify_token(version, key, msg, sig):
    mac = hmac.new(key, msg, hashlib.sha256).digest()
    if version == 1:
        mac = mac[:16]
    return hmac.compare_digest(mac, bytes(sig))


class Authenticator:
    def __init__(self, state_path, ctl_dir):
        self.state_path = state_path
        self.ctl = ctl_dir
        self.st = self._load()
        self.agreement = ec.generate_private_key(ec.SECP256R1())
        self.pin_token = os.urandom(32)
        self.pin_token_perms = 0
        self.consecutive_bad = 0
        self.io = None  # set by the transport, used for keepalive/cancel

    # ---- persistent state ----
    def _load(self):
        try:
            with open(self.state_path) as f:
                return json.load(f)
        except FileNotFoundError:
            return self._fresh()

    @staticmethod
    def _fresh():
        return {"pin_hash": None, "retries": PIN_RETRIES, "counter": 0, "creds": {}}

    def _save(self):
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.st, f, indent=1)
        os.replace(tmp, self.state_path)

    # ---- user presence ----
    def _presence_mode(self):
        try:
            with open(os.path.join(self.ctl, "presence")) as f:
                return f.read().strip() or "auto"
        except OSError:
            return "auto"

    def user_presence(self, what):
        mode = self._presence_mode()
        log(up="requested", op=what, mode=mode)
        deadline = time.monotonic() + PRESENCE_TIMEOUT
        touch = os.path.join(self.ctl, "touch")
        first = True
        while time.monotonic() < deadline:
            if self.io.keepalive_or_cancel(first):
                log(up="cancelled", op=what)
                raise CtapError(KEEPALIVE_CANCEL)
            first = False
            if mode == "auto":
                time.sleep(0.3)
                log(up="granted", op=what)
                return
            if mode == "manual" and os.path.exists(touch):
                os.unlink(touch)
                log(up="granted", op=what)
                return
            mode = self._presence_mode()
        log(up="timeout", op=what)
        raise CtapError(USER_ACTION_TIMEOUT if mode == "manual" else OPERATION_DENIED)

    # ---- CTAP2 dispatch ----
    def handle_cbor(self, data):
        if not data:
            raise CtapError(INVALID_COMMAND)
        cmd, body = data[0], data[1:]
        try:
            params = cbor.decode(body) if body else {}
        except Exception:
            raise CtapError(INVALID_CBOR)
        handler = {
            0x01: self.make_credential,
            0x02: self.get_assertion,
            0x04: self.get_info,
            0x06: self.client_pin,
            0x07: self.reset,
            0x0B: self.selection,
        }.get(cmd)
        if handler is None:
            log(ctap="unsupported", cmd=hex(cmd))
            raise CtapError(INVALID_COMMAND)
        resp = handler(params)
        return b"" if resp is None else cbor.encode(resp)

    def get_info(self, _p):
        return {
            1: ["FIDO_2_0", "FIDO_2_1"],
            2: ["hmac-secret"],
            3: AAGUID,
            4: {"rk": False, "up": True, "plat": False,
                "clientPin": self.st["pin_hash"] is not None,
                "pinUvAuthToken": True},
            5: 1200,
            6: [2, 1],
            0x0D: 4,  # minPINLength
        }

    def selection(self, _p):
        self.user_presence("selection")

    def reset(self, _p):
        self.user_presence("reset")
        self.st = self._fresh()
        self._save()
        self.pin_token = os.urandom(32)
        log(reset="done")

    # ---- PIN handling ----
    def _check_pin_auth(self, params, client_data_hash, perm, k_auth, k_proto, required):
        """Returns True if a valid pinUvAuthParam was supplied (=> UV).
        k_auth/k_proto: CBOR keys of pinUvAuthParam/-Protocol (differ per command).
        required: makeCredential needs the PIN once one is set; getAssertion
        without it just proceeds with uv=0 (CTAP2 spec; systemd's pre-flight
        probe relies on that)."""
        auth = params.get(k_auth)
        if auth is None:
            if required and self.st["pin_hash"] is not None:
                raise CtapError(PIN_REQUIRED)
            return False
        if len(auth) == 0:  # authenticatorSelection-style probe
            self.user_presence("pin-probe")
            raise CtapError(PIN_NOT_SET if self.st["pin_hash"] is None else PIN_INVALID)
        proto = params.get(k_proto, 1)
        if self.st["pin_hash"] is None:
            raise CtapError(PIN_NOT_SET)
        if not verify_token(proto, self.pin_token, client_data_hash, auth):
            log(pinauth="invalid")
            raise CtapError(PIN_AUTH_INVALID)
        if self.pin_token_perms and not (self.pin_token_perms & perm):
            raise CtapError(PIN_AUTH_INVALID)
        return True

    def _pin_shared(self, params):
        proto = params.get(1)
        if proto not in (1, 2) or 3 not in params:
            raise CtapError(MISSING_PARAMETER)
        return PinProtocol(proto, self.agreement, params[3])

    def _regen(self):
        self.agreement = ec.generate_private_key(ec.SECP256R1())

    def _verify_pin_hash(self, pp, pin_hash_enc):
        if self.st["retries"] <= 0:
            raise CtapError(PIN_BLOCKED)
        if self.consecutive_bad >= 3:
            raise CtapError(PIN_AUTH_BLOCKED)
        got = pp.decrypt(pin_hash_enc)[:16]
        self.st["retries"] -= 1
        if not hmac.compare_digest(got, unb64(self.st["pin_hash"])):
            self._regen()
            self.consecutive_bad += 1
            self._save()
            log(pin="wrong", retries=self.st["retries"])
            raise CtapError(PIN_BLOCKED if self.st["retries"] <= 0 else PIN_INVALID)
        self.st["retries"] = PIN_RETRIES
        self.consecutive_bad = 0
        self._save()

    def _set_new_pin(self, pp, new_pin_enc):
        padded = pp.decrypt(new_pin_enc)
        if len(padded) < 64:
            raise CtapError(PIN_POLICY_VIOLATION)
        pin = padded.split(b"\x00", 1)[0]
        if len(pin.decode("utf-8", "replace")) < 4 or len(pin) > 63:
            raise CtapError(PIN_POLICY_VIOLATION)
        self.st["pin_hash"] = b64(hashlib.sha256(pin).digest()[:16])
        self.st["retries"] = PIN_RETRIES
        self._save()

    def client_pin(self, p):
        sub = p.get(2)
        if sub == 0x01:  # getPinRetries
            return {3: self.st["retries"]}
        if sub == 0x02:  # getKeyAgreement
            return {1: cose_p256(self.agreement.public_key(), -25)}
        if sub == 0x03:  # setPIN
            if self.st["pin_hash"] is not None:
                raise CtapError(PIN_AUTH_INVALID)
            pp = self._pin_shared(p)
            if not pp.verify(p[5], p[4]):
                raise CtapError(PIN_AUTH_INVALID)
            self._set_new_pin(pp, p[5])
            log(pin="set")
            return None
        if sub == 0x04:  # changePIN
            if self.st["pin_hash"] is None:
                raise CtapError(PIN_NOT_SET)
            pp = self._pin_shared(p)
            if not pp.verify(p[5] + p[6], p[4]):
                raise CtapError(PIN_AUTH_INVALID)
            self._verify_pin_hash(pp, p[6])
            self._set_new_pin(pp, p[5])
            self.pin_token = os.urandom(32)
            log(pin="changed")
            return None
        if sub in (0x05, 0x09):  # getPinToken / ...UsingPinWithPermissions
            if self.st["pin_hash"] is None:
                raise CtapError(PIN_NOT_SET)
            pp = self._pin_shared(p)
            self._verify_pin_hash(pp, p[6])
            self.pin_token = os.urandom(32)
            self.pin_token_perms = p.get(9, 0) if sub == 0x09 else 0
            log(pin="ok", perms=self.pin_token_perms)
            return {2: pp.encrypt(self.pin_token)}
        raise CtapError(INVALID_PARAMETER)

    # ---- credentials ----
    def make_credential(self, p):
        for k in (1, 2, 3, 4):
            if k not in p:
                raise CtapError(MISSING_PARAMETER)
        cdh, rp = p[1], p[2]
        if not any(a.get("alg") == -7 and a.get("type") == "public-key" for a in p[4]):
            raise CtapError(UNSUPPORTED_ALGORITHM)
        opts = p.get(7, {})
        if opts.get("rk"):
            raise CtapError(UNSUPPORTED_OPTION)
        uv = self._check_pin_auth(p, cdh, 0x01, 8, 9, True)
        self.user_presence("makeCredential")
        rp_hash = hashlib.sha256(rp["id"].encode()).digest()
        key = ec.generate_private_key(ec.SECP256R1())
        cred_id = os.urandom(48)
        self.st["creds"][b64(cred_id)] = {
            "rp": rp["id"],
            "rp_hash": b64(rp_hash),
            "key": b64(key.private_numbers().private_value.to_bytes(32, "big")),
            "cr_uv": b64(os.urandom(32)),
            "cr_nouv": b64(os.urandom(32)),
        }
        self.st["counter"] += 1
        self._save()
        flags = FLAG_UP | FLAG_AT | (FLAG_UV if uv else 0)
        ext = p.get(6, {})
        ext_out = b""
        if ext.get("hmac-secret") is True:
            ext_out = cbor.encode({"hmac-secret": True})
            flags |= FLAG_ED
        acd = AAGUID + struct.pack(">H", len(cred_id)) + cred_id + cbor.encode(cose_p256(key.public_key(), -7))
        auth_data = rp_hash + bytes([flags]) + struct.pack(">I", self.st["counter"]) + acd + ext_out
        sig = key.sign(auth_data + cdh, ec.ECDSA(hashes.SHA256()))
        log(op="makeCredential", rp=rp["id"], uv=int(uv), cred=cred_id[:6].hex())
        return {1: "packed", 2: auth_data, 3: {"alg": -7, "sig": sig}}

    def get_assertion(self, p):
        for k in (1, 2):
            if k not in p:
                raise CtapError(MISSING_PARAMETER)
        rp_id, cdh = p[1], p[2]
        rp_hash = hashlib.sha256(rp_id.encode()).digest()
        cred = cred_id = None
        for d in p.get(3, []):
            c = self.st["creds"].get(b64(d["id"]))
            if c and unb64(c["rp_hash"]) == rp_hash:
                cred, cred_id = c, d["id"]
                break
        opts = p.get(5, {})
        uv = self._check_pin_auth(p, cdh, 0x02, 6, 7, False)
        if cred is None:
            log(op="getAssertion", result="no-credentials")
            raise CtapError(NO_CREDENTIALS)
        want_up = opts.get("up", True)
        if want_up:
            self.user_presence("getAssertion")
        flags = (FLAG_UP if want_up else 0) | (FLAG_UV if uv else 0)
        ext_out = b""
        hs = p.get(4, {}).get("hmac-secret")
        if hs is not None:
            pp = PinProtocol(hs.get(4, 1), self.agreement, hs[1])
            if not pp.verify(hs[2], hs[3]):
                raise CtapError(INVALID_PARAMETER)
            salts = pp.decrypt(hs[2])
            if len(salts) not in (32, 64):
                raise CtapError(INVALID_PARAMETER)
            cr = unb64(cred["cr_uv"] if uv else cred["cr_nouv"])
            out = b"".join(hmac.new(cr, salts[i:i + 32], hashlib.sha256).digest()
                           for i in range(0, len(salts), 32))
            ext_out = cbor.encode({"hmac-secret": pp.encrypt(out)})
            flags |= FLAG_ED
        self.st["counter"] += 1
        self._save()
        auth_data = rp_hash + bytes([flags]) + struct.pack(">I", self.st["counter"]) + ext_out
        priv = ec.derive_private_key(int.from_bytes(unb64(cred["key"]), "big"), ec.SECP256R1())
        sig = priv.sign(auth_data + cdh, ec.ECDSA(hashes.SHA256()))
        log(op="getAssertion", rp=rp_id, up=int(want_up), uv=int(uv),
            hmac=int(hs is not None), cred=cred_id[:6].hex())
        return {1: {"type": "public-key", "id": cred_id}, 2: auth_data, 3: sig}


class HidTransport:
    """CTAPHID framing over a 64-byte-report hidg character device."""

    def __init__(self, path, auth):
        self.fd = os.open(path, os.O_RDWR)
        self.auth = auth
        auth.io = self
        self.channels = set()
        self.busy_cid = None
        self.last_keepalive = 0.0
        self.pending = []

    def _write(self, cid, cmd, payload):
        pkt = struct.pack(">IBH", cid, 0x80 | cmd, len(payload)) + payload[:57]
        self._send(pkt.ljust(64, b"\x00"))
        rest, seq = payload[57:], 0
        while rest:
            self._send((struct.pack(">IB", cid, seq) + rest[:59]).ljust(64, b"\x00"))
            rest, seq = rest[59:], seq + 1

    # The USB host side disappears whenever the VM resets or is killed, or a
    # host driver rebinds; a real key just waits to be enumerated again.
    def _send(self, pkt):
        try:
            os.write(self.fd, pkt)
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            log(usb="write-dropped", err=e.errno)

    def _error(self, cid, code):
        self._write(cid, CMD_ERROR, bytes([code]))

    def _read_packet(self, timeout=None):
        if self.pending:
            return self.pending.pop(0)
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return None
        try:
            return os.read(self.fd, 64).ljust(64, b"\x00")
        except OSError as e:
            log(usb="disconnected", err=e.errno)
            self.channels.clear()
            time.sleep(0.5)
            return None

    def keepalive_or_cancel(self, force):
        """Called while waiting for user presence. Returns True on CANCEL."""
        now = time.monotonic()
        if force or now - self.last_keepalive >= 0.1:
            self._write(self.busy_cid, CMD_KEEPALIVE, b"\x02")  # UPNEEDED
            self.last_keepalive = now
        pkt = self._read_packet(0.05)
        if pkt is None:
            return False
        cid, cmd = struct.unpack(">IB", pkt[:5])
        if cid == self.busy_cid and cmd == (0x80 | CMD_CANCEL):
            return True
        if cmd & 0x80 and cmd != (0x80 | CMD_INIT):
            self._error(cid, ERR_CHANNEL_BUSY)
        else:
            self.pending.append(pkt)
        return False

    def serve(self):
        log(state="ready")
        while True:
            pkt = self._read_packet()
            if pkt is None:
                continue
            cid, cmd = struct.unpack(">IB", pkt[:5])
            if not cmd & 0x80:
                continue  # stray continuation
            cmd &= 0x7F
            bcnt = struct.unpack(">H", pkt[5:7])[0]
            data = pkt[7:7 + bcnt]
            seq = 0
            while len(data) < bcnt:
                cont = self._read_packet(1.0)
                if cont is None:
                    break
                ccid, cseq = struct.unpack(">IB", cont[:5])
                if ccid != cid:
                    continue
                if cseq != seq:
                    self._error(cid, ERR_INVALID_SEQ)
                    break
                data += cont[5:5 + bcnt - len(data)]
                seq += 1
            if len(data) < bcnt:
                continue
            self.dispatch(cid, cmd, data)

    def dispatch(self, cid, cmd, data):
        if cmd == CMD_INIT:
            new = int.from_bytes(os.urandom(4), "big") & 0x7FFFFFFF or 1
            if cid != BROADCAST:
                new = cid
            self.channels.add(new)
            resp = data[:8] + struct.pack(">IBBBBB", new, 2, 1, 0, 0, CAP_WINK | CAP_CBOR | CAP_NMSG)
            self._write(cid, CMD_INIT, resp)
            return
        if cid == BROADCAST or cid not in self.channels:
            self._error(cid, 0x0B)  # ERR_INVALID_CHANNEL
            return
        if cmd == CMD_PING:
            self._write(cid, CMD_PING, data)
        elif cmd == CMD_WINK:
            log(wink=1)
            self._write(cid, CMD_WINK, b"")
        elif cmd == CMD_CANCEL:
            pass
        elif cmd == CMD_CBOR:
            self.busy_cid = cid
            try:
                body = self.auth.handle_cbor(data)
                self._write(cid, CMD_CBOR, bytes([OK]) + body)
            except CtapError as e:
                log(ctap_error=hex(e.code), cmd=hex(data[0]) if data else "-")
                self._write(cid, CMD_CBOR, bytes([e.code]))
            finally:
                self.busy_cid = None
        else:
            self._error(cid, ERR_INVALID_CMD)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--hidg", default="/dev/hidg0")
    ap.add_argument("--state", required=True, help="JSON state file (created if missing)")
    ap.add_argument("--ctl", required=True, help="control directory (presence/touch files)")
    a = ap.parse_args()
    os.makedirs(a.ctl, exist_ok=True)
    auth = Authenticator(a.state, a.ctl)
    HidTransport(a.hidg, auth).serve()


if __name__ == "__main__":
    sys.exit(main())
