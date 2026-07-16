# Public / Private Boundary

This repository is designed to be public. It should contain reusable setup
knowledge, not private project evidence.

## Safe To Commit

- Placeholder-based setup docs.
- Dependency categories and verification commands.
- Skill templates without local paths.
- Synthetic fixtures and manifests.
- Public upstream repo names and URLs.
- Public example command shapes using placeholders.
- Validation scripts that do not mutate devices by default.

## Do Not Commit

- Local absolute paths.
- Device serials or network endpoint values from real runs.
- Private repository names, app package IDs, launch activities, signing
  config, or release payload paths.
- Generated APKs, AABs, idsig files, keystores, loader binaries, SDK packages,
  debug symbols, downloaded tools, or cache folders.
- Screenshots, screen recordings, logcat dumps, Perfetto traces, cast
  captures, media frames, or raw device diagnostics.
- Private visual effect behavior, study logic, tuning constants, or product
  parity notes.

## Evidence Pattern

Publish sanitized summaries:

- tool category;
- pass, partial, fail, or blocked state;
- authority boundary;
- command goal;
- provider used;
- placeholder command shape;
- artifact type, not artifact path;
- cleanup attempted and result.

Keep private:

- exact local paths;
- raw logs;
- serials;
- package names for private apps;
- screenshots and captures;
- pairing material;
- generated binaries.

## Boundary Scan

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
```

The scan is intentionally conservative. If it flags a public repo name that is
actually safe, add a narrow allowlist entry with a comment explaining why.
