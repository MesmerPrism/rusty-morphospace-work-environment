# Contributing

Thank you for improving the Rusty Morphospace work environment. This repository
is public workflow infrastructure, so portability and fail-closed behavior are
part of every change.

## Before Editing

1. Read `AGENTS.md`, `README.md`, and the focused document for the area.
2. Keep work within one explicit objective and list non-scope.
3. Preserve existing project events, receipts, and contributor-local files.
4. Use placeholders for machine paths and keep local output under ignored
   `local/`, `artifacts/`, or temporary directories.

For local skill work, read
[Local Skill Bootstrap](docs/LOCAL_SKILL_BOOTSTRAP.md). For schema or workflow
changes, read [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md)
and [Instruction Synchronization](docs/INSTRUCTION_SYNCHRONIZATION.md).

## Validation

During iteration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -SelfTest `
  -Tier Quick
```

Use `Standard` before handing off workflow-automation changes. Use `Deep` for
authority, release, or broad consolidation changes. Also run `git diff --check`.
No repository check authorizes a headset or ADB action.

## Pull Requests

Describe the decision, scope/non-scope, authority impact, public/private impact,
validation run, and rollback. Note instruction surfaces reviewed or updated.
Do not include generated provenance files, local paths, device identifiers,
private package names, raw device evidence, SDKs, APKs, or signing material.

Schema and script changes should include a valid example plus a damaged or
negative regression whenever the failure behavior matters.
