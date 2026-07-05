# Skill Installation

This repo includes portable skill templates under `skills/`. They are designed
for contributors to copy into their local agent skill directory and customize
through local config, not by editing committed files.

## Included Templates

| Skill | Purpose |
| --- | --- |
| `rusty-morphospace-context` | Route repo-family work, lane ownership, public/private boundary, and onboarding state. |
| `system-engineering` | Structure architecture work around authority, interfaces, observability, validation, and risk. |
| `rust-work-graph` | Inventory source roots, dependency pressure, instruction surfaces, and graph snapshots. |
| `meta-quest-workflow` | Route live Quest, ADB, APK, logcat, screenshots, Perfetto, and Wi-Fi ADB work to the public device workflow. |

## Dry Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root>
```

## Install

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot <codex-skills-root> `
  -Execute
```

The script refuses to overwrite an existing skill directory. To update an
installed skill, review the diff and replace it intentionally.

## Customization

Do not edit committed skill templates with local paths. Put local paths in:

- `local/local.paths.json`;
- your agent configuration;
- your shell profile;
- ignored per-repo environment files.

Skill templates should use placeholders such as `<workspace-root>` and refer
to docs in this repo.
