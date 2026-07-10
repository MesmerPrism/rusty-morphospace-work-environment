# Validation

Use validation in layers. Do not run live device operations just to prove docs
or manifests parse.

## Work Environment Repo

Quick checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ProjectWorkspace.ps1 -SelfTest
git diff --check
```

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

Validate an instantiated project workspace:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot <project-root>\morphospace
```

The scaffold self-test creates a temporary project workspace, validates it,
proves that a second invocation cannot overwrite it, and removes only its own
temporary directory.

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
