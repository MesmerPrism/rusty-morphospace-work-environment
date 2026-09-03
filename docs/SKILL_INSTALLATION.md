# Skill Installation

This repository ships four local portable skill routers. The canonical
`meta-quest-workflow` source is owned by the public
`MesmerPrism/meta-quest-agent-workflow` repository. Use the managed installer;
do not copy skills by hand or place contributor paths in committed templates.

| Skill | Primary use |
| --- | --- |
| `rusty-morphospace` | Public architecture, ownership, project workflow, validation, boundaries, and agent routing. |
| `rusty-morphospace-context` | Machine-local work-environment and installed-provenance resolution. |
| `system-engineering` | Authority, contracts, interfaces, observability, and validation. |
| `rust-work-graph` | Bounded inventories, dependency/diff maps, and graph receipts. |
| `meta-quest-workflow` (external canonical source) | Live Quest/ADB/APK/evidence routing to the public device workflow. |

For the complete new-machine, existing-installation, update, backup, and
verification procedure, use [Local Skill Bootstrap](LOCAL_SKILL_BOOTSTRAP.md).

The short path is:

```powershell
$SkillRoot = Join-Path $env:USERPROFILE ".codex\skills"
$MetaWorkflowRoot = "<workspace-root>\meta-quest-agent-workflow"

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot $MetaWorkflowRoot `
  -TargetRoot $SkillRoot `
  -Action Plan

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot $MetaWorkflowRoot `
  -TargetRoot $SkillRoot `
  -Action Install `
  -Execute

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot $MetaWorkflowRoot `
  -TargetRoot $SkillRoot `
  -Action Verify
```

`Install` never overwrites an existing directory. `Update` is a separate,
explicit operation and creates a backup outside the skill-discovery root.
Plan and Verify report source-unowned files without treating them as managed
drift. The separate `PruneUnmanaged` action is dry-run by default and can remove
only one skill's fingerprinted inventory after a verified complete backup.
For Meta, `.morphospace-skill-source.json` binds the canonical Meta repository
and commit while `references/local-work-environment.json` independently binds
this Work Environment checkout. The additional generated
`references/local-meta-quest-playbooks.json` binds the exact local Meta
repository, Git tree, clean status, and docs paths. The installed router uses
that source only after validation; otherwise it resolves public playbooks at
the provenance commit rather than floating `main`.
