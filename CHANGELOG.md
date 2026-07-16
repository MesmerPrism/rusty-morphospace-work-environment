# Changelog

All notable changes to the portable work environment are recorded here.

## 0.5.0 - candidate

### Changed

- PowerShell 7.6 LTS or newer, invoked as `pwsh`, is the authoritative host for
  validation, automation, child authority runners, and release tooling.
- Windows PowerShell 5.1 support is reduced to a bootstrap detector with an
  explicit PowerShell 7 installation route.
- CI validates PowerShell 7 Quick on Windows and Linux plus Standard on
  Windows; the duplicate Windows PowerShell 5.1 job is removed.

### Added

- A host-policy validator that checks the running version/edition and rejects
  new authoritative `powershell.exe`, `& powershell`, or `shell: powershell`
  execution paths.

## 0.3.0 - 2026-07-15

### Added

- Managed Plan/Install/Verify/Update lifecycle for the four portable skills,
  including source hashes, local locator, dirty-source policy, and backups.
- Current protocol-v2 templates and the `hello-morphospace-v2` walkthrough.
- Quick, Standard, and Deep aggregate validation tiers.
- Documentation-link, environment-profile, skill-template, and skill-bootstrap
  regression tests.
- Windows PowerShell 5.1 and PowerShell 7 CI, contributor guidance, and security
  reporting guidance.

### Fixed

- Scaffold-generated schema links now use raw, revision-pinned URLs.
- Strict environment checks reject required placeholders and configured repo
  paths that do not exist.
- Python 3.11 and profile-scoped JDK 17 minimums are checked explicitly.
- A single aggregate failure is no longer lost by Windows PowerShell scalar
  `.Count` behavior.
- Validation-authority Git executable selection is deterministic when multiple
  Git installations are discoverable.
- Rusty LSL is present in the portable repo-lane and local-path manifests.

### Changed

- `rusty-morphospace-context` is a concise state-first router and no longer
  carries transient roadmap status.
- Advanced receipt-security detail moved out of the first-hop autonomous guide.

## 0.2.1 - 2026-07-14

- Corrected the portable identity bound to 2 through 128 characters while
  preserving v1/v2 read compatibility.

## 0.2.0 - 2026-07-11

- Added protocol-v2 project, feature-lock, workspace-state, and authority
  contracts while preserving additive v1 migration.

## 0.1.0 - 2026-07-11

- Established the first portable project/module workflow baseline.
