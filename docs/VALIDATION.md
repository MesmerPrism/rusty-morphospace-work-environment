# Validation

Use validation in layers. Do not run live device operations just to prove docs
or manifests parse.

## Work Environment Repo

Quick checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest -Tier Quick
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ProjectWorkspace.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-DocumentationLinks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-SkillTemplates.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-EnvironmentValidation.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-LocalSkillBootstrap.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FeatureLockResolver.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ProjectIsolation.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExecutedPushReceipt.ps1 -SelfTest
git diff --check
```

`Quick` covers portable contracts, scaffolding, skill bootstrap, and docs.
`Standard` additionally runs the work-unit automation suite. `Deep` adds the
closed-room validation-authority suites. A device is not part of any of these
tiers.

Validate a configured contributor machine separately:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -ConfigPath .\local\local.paths.json `
  -Profile Core `
  -Strict
```

Use `-Profile Quest` when the Android SDK, NDK, JDK 17, and ADB toolchain are
required. Strict mode rejects required placeholders and missing configured repo
paths; Python 3.11 is required for every profile.

JSON parse:

```powershell
Get-ChildItem .\manifests,.\schemas,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```

PowerShell parse:

```powershell
Get-ChildItem .\scripts -Filter *.ps1 -File |
  ForEach-Object {
    [scriptblock]::Create((Get-Content -Raw $_.FullName)) | Out-Null
  }
```

## Project Workflow Contracts

The workflow validator checks more than JSON syntax. It enforces:

- closed-world activation and declared-module references;
- one authority owner per parameter;
- module maturity and iteration state vocabularies;
- repository/path scope, non-scope, acceptance, risk, device, and push fields;
- at most one active unit and consistent compact state;
- increasing, parseable JSONL iteration events;
- stable-promotion gates, rollback, and an independent consumer or
  conformance harness;
- required instruction synchronization for authority, module-layout,
  activation, validation, device-policy, repo-routing, and boundary changes.
- exact-lock/materialization source modes, resource requirements, repository
  revision checkpoints, and extraction-bound v2 stable promotions.

Validate an instantiated project workspace:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot <project-root>\morphospace
```

The checked-in v2 onboarding workspace is a semantic regression target:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot .\examples\hello-morphospace-v2\morphospace
```

The scaffold self-test creates a temporary project workspace, validates it,
proves that a second invocation cannot overwrite it, and removes only its own
temporary directory.

The project-isolation test creates two temporary Git repositories, locks their
exact commits and trees, materializes detached clean copies, rejects address
replacement, and proves that overlapping exclusive local resource claims fail
closed. It performs no device operations.

The feature-lock resolver self-test proves dependency closure, descriptor and
source hashing, exact effect unions, selected-lock-plus-runtime-input
activation, absent-feature rejection, ambient-input rejection, and stale-lock
fingerprint rejection.

Work-unit automation self-tests keep missing/spoofed validation receipts,
dirty-path overlap, and out-of-scope changed paths as hard failures. A passing
device receipt is incomplete without explicit serial scope, cleanup, and zero
bounded package/system fatal counts.
They also simulate partial cross-repo commits, interrupted builds, and
interrupted device work: missing/unsafe cleanup receipts reject, while typed
safe receipts restore only the current-unit pointer and leave Git/devices
untouched.

## Executed Push Receipts

Validate externally produced successful push evidence with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExecutedPushReceipt.ps1 `
  -Path <project-root>\morphospace\receipts\<executed-push-receipt>.json
```

The semantic validator requires dependency order to equal actual execution
order, exactly one planning ref last, full old/new/readback revisions, exact
remote equality, fast-forward ancestry, no force push, passing referenced
validation gates, and rollback points that exactly reverse execution order.
It does not execute Git or contact a remote.

## Source Repos

Each source repo owns its own checks. Typical Rust checks:

```powershell
cargo fmt --all --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

For broad repo-family orientation, start with a tracked-file inventory before
deeper graph or pattern scans.

## Quest Device Work

Live device validation is not a docs check. Use the public Meta Quest workflow
and record:

- provider used;
- command goal;
- selected device placeholder;
- foreground before and after;
- install/launch/logcat/screenshot/Perfetto commands, if used;
- artifact types and cleanup state.

Keep raw device artifacts private unless a public redaction gate exists.
