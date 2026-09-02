# Security Policy

## Supported versions

Stratum has not made a stable release. Security fixes are applied to the current `main` branch only; older commits and development snapshots are not supported release lines.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/griwes/stratum.nvim/security/advisories/new) when it is available. Do not disclose a suspected vulnerability in a public issue, discussion, or pull request.

If private vulnerability reporting is unavailable, contact the maintainer through a private channel currently listed on the maintainer's GitHub profile. Include the affected revision, impact, reproduction steps, and any suggested mitigation. Avoid including secrets or unrelated personal data.

There is no guaranteed response SLA while the project is pre-release. Reports will be triaged according to impact and reproducibility.

## Scope

Security reports are especially useful for unintended command execution, path traversal, authentication or approval bypass, secret disclosure, unsafe persistence, and denial-of-service behavior caused by untrusted input. The project does not claim to sandbox Neovim, user configuration, installed plugins, or explicitly configured external programs.

Managed Gitseer installation executes a downloaded release binary or invokes
Cargo against the configured repository and revision. GitHub release downloads
are checked against the checksum published beside the asset and are rejected
unless `gitseer capabilities` advertises the protocol Stratum expects. Those
checks detect corruption and incompatible binaries; they do not make a
compromised GitHub repository, release, Cargo source, or user override trusted.
