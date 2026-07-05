# Validation

Use validation in layers. Do not run live device operations just to prove docs
or manifests parse.

## Work Environment Repo

Quick checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest
git diff --check
```

JSON parse:

```powershell
Get-ChildItem .\manifests,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```

PowerShell parse:

```powershell
Get-ChildItem .\scripts -Filter *.ps1 -File |
  ForEach-Object {
    [scriptblock]::Create((Get-Content -Raw $_.FullName)) | Out-Null
  }
```

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
