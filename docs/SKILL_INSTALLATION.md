# Skill Installation

This repository ships five portable skill routers. Use the managed installer;
do not copy them by hand or place contributor paths in committed templates.

| Skill | Primary use |
| --- | --- |
| `rusty-morphospace` | Public architecture, ownership, project workflow, validation, boundaries, and agent routing. |
| `rusty-morphospace-context` | Explicit machine-local work-environment and installed-provenance resolution. |
| `system-engineering` | Authority, contracts, interfaces, observability, and validation. |
| `rust-work-graph` | Bounded inventories, dependency/diff maps, and graph receipts. |
| `meta-quest-workflow` | Live Quest/ADB/APK/evidence routing to the public device workflow. |

For the complete new-machine, existing-installation, update, backup, and
verification procedure, use [Local Skill Bootstrap](LOCAL_SKILL_BOOTSTRAP.md).

The short path is:

```powershell
$SkillRoot = Join-Path $env:USERPROFILE ".codex\skills"

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Plan

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Install `
  -Execute

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Verify
```

`Install` never overwrites an existing directory. `Update` is a separate,
explicit operation and creates a backup outside the skill-discovery root.
Plan and Verify report source-unowned files without treating them as managed
drift. The separate `PruneUnmanaged` action is dry-run by default and can remove
only one skill's fingerprinted inventory after a verified complete backup.
