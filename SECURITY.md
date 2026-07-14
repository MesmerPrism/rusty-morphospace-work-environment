# Security Policy

## Reporting A Vulnerability

Do not open a public issue for a vulnerability, leaked credential, signing
material, private package identity, or device/pairing artifact. Use the
repository's private
[GitHub security-advisory form](https://github.com/MesmerPrism/rusty-morphospace-work-environment/security/advisories/new).

Include the affected release/commit, impact, minimal reproduction, and suggested
containment. Redact local paths, device serials, tokens, keys, private payloads,
and raw captures unless the private report specifically requires them.

## Supported Versions

Security fixes target the newest published portable release. Historical
manifests remain readable for additive migration, but callers should not assume
old automation or authority paths receive backports.

## Scope

Relevant issues include unsafe path handling, unintended overwrite/deletion,
receipt or provenance forgery, validation false greens, public/private boundary
leaks, and commands that mutate Git, devices, networks, or external state beyond
their documented authority.
