# Skill Templates

These are portable Codex-style skill templates for Rusty Morphospace work.

Install them with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File ..\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Execute
```

The templates intentionally use placeholders and repo-relative docs instead of
local paths. Put workstation-specific paths in ignored `local/` files or in
your agent configuration.

The Morphospace and system-engineering templates route project work through
the portable project spec, feature lock, module lifecycle, and autonomous
iteration protocol in `docs/`. All four templates also follow the instruction
synchronization matrix so durable routing changes stay aligned without copying
long recipes into skill entrypoints.
