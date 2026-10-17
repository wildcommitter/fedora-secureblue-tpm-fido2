#!/usr/bin/env python3
"""Bake a client PIN into a FIDO2 key non-interactively.

  fido2-pin.py ensure  <hidraw> : PIN from $FIDO2_PIN; if the key has a
                         different PIN, $FIDO2_CURRENT_PIN must hold it.
  fido2-pin.py verify  <hidraw> : check $FIDO2_PIN against the key.
  fido2-pin.py info    <hidraw> : print "pin=set|unset retries=N".

fido2-token(1) reads PINs only from a TTY, hence this helper.
"""
import os
import sys

from fido2.ctap import CtapError
from fido2.ctap2 import Ctap2
from fido2.ctap2.pin import ClientPin
from fido2.hid import CtapHidDevice
from fido2.hid.linux import get_descriptor, open_connection


def open_dev(path):
    desc = get_descriptor(path)
    return Ctap2(CtapHidDevice(desc, open_connection(desc)))


def pin_ok(cp, pin):
    try:
        cp.get_pin_token(pin)
        return True
    except CtapError as e:
        if e.code == CtapError.ERR.PIN_INVALID:
            return False
        raise


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("ensure", "verify", "info"):
        sys.exit(__doc__)
    cmd, path = sys.argv[1], sys.argv[2]
    ctap = open_dev(path)
    has_pin = bool(ctap.info.options.get("clientPin"))
    cp = ClientPin(ctap)
    if cmd == "info":
        retries = cp.get_pin_retries()[0] if has_pin else "-"
        print(f"pin={'set' if has_pin else 'unset'} retries={retries}")
        return
    pin = os.environ.get("FIDO2_PIN", "")
    if len(pin) < 4:
        sys.exit("fido2-pin: FIDO2_PIN must be at least 4 characters")
    if cmd == "verify":
        if not has_pin:
            sys.exit("fido2-pin: key has no PIN set")
        sys.exit(0 if pin_ok(cp, pin) else "fido2-pin: FIDO2_PIN does not match the key")
    if not has_pin:
        cp.set_pin(pin)
        print("fido2-pin: PIN set on key")
        return
    retries = cp.get_pin_retries()[0]
    if retries <= 3:
        sys.exit(f"fido2-pin: only {retries} PIN retries left on the key, refusing to guess")
    if pin_ok(cp, pin):
        print("fido2-pin: key already has the configured PIN")
        return
    current = os.environ.get("FIDO2_CURRENT_PIN", "")
    if not current:
        sys.exit("fido2-pin: key has a different PIN; set FIDO2_CURRENT_PIN to change it")
    cp.change_pin(current, pin)
    print("fido2-pin: PIN changed on key")


if __name__ == "__main__":
    main()
