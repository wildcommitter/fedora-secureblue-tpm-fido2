# Security policy

scroll-secure is unaudited. We want it broken, so we can fix it.

## Reporting

Report vulnerabilities **privately** through GitHub:
**Security → Report a vulnerability** (a private security advisory). Please include:

- the affected part (`image/`, `image/files-luks/` tokenvault, `lockscreen/`, the Secure Boot
  key script, the docs' install steps)
- what an attacker needs (physical access, root, a local user, network) and what they get
- reproduction steps; the KVM e2e harness in `test/bootc/` is usually the fastest way to
  show it

Use public issues for everything that isn't exploitable.

## What happens next

Confirmed findings get a fix, credit in the commit and release notes (unless you'd rather
not), and a regression test in the e2e suite where one is possible.

## Scope

The threat model, including what is knowingly out of scope (runtime root compromise,
downgrade to an older signed UKI, firmware implants, VM escape, the recovery passphrase),
is at https://wildcommitter.github.io/fedora-secureblue-tpm-fido2/threat-model.html.
Findings that break one of the "out of scope" assumptions in a new way are still welcome.

Issues in secureblue, systemd, bootc or Fedora packages belong upstream; we'll help route
them.
