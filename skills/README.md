# Skill Templates

These are the four Work Environment-owned portable Codex-style skill templates
for Rusty Morphospace work. The canonical `meta-quest-workflow` template is
owned by `meta-quest-agent-workflow` and is supplied to the installer through
`-MetaQuestWorkflowRepoRoot`.

Install them with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File ..\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot <meta-quest-agent-workflow-root> `
  -TargetRoot <codex-skills-root> `
  -Execute
```

The templates intentionally use placeholders and repo-relative docs instead of
local paths. Put workstation-specific paths in ignored `local/` files or in
your agent configuration.

Plan and Verify report files outside the managed template inventory. Updates
preserve them. Only the explicit, fingerprint-bound, backup-first
`PruneUnmanaged -Execute` action may remove the exact reported files.

The public `rusty-morphospace` and `system-engineering` templates route project
work through the portable project spec, feature lock, module lifecycle, and
autonomous iteration protocol in `docs/`. The focused
`rusty-morphospace-context` template resolves an installed machine-local clone
and hands portable guidance to `rusty-morphospace`. All five templates follow
the instruction synchronization matrix so durable routing changes stay aligned
without copying long recipes into skill entrypoints.
