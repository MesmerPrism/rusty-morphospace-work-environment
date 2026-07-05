# Skill Templates

These are portable Codex-style skill templates for Rusty Morphospace work.

Install them with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File ..\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Execute
```

The templates intentionally use placeholders and repo-relative docs instead of
local paths. Put workstation-specific paths in ignored `local/` files or in
your agent configuration.
