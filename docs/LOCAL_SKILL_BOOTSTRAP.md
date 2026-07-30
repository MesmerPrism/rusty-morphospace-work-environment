# Local Skill Bootstrap

This guide installs the five Rusty Morphospace skill routers into a contributor's
own agent environment with verifiable source provenance. It supports a new
machine and an existing installation without silently overwriting local work.

## 1. Establish The Local Clone

Clone the work environment and keep its location in your shell or ignored local
configuration:

```powershell
$WorkEnvironmentRoot = "<workspace-root>\rusty-morphospace-work-environment"
$env:RUSTY_MORPHOSPACE_WORK_ENVIRONMENT = $WorkEnvironmentRoot
Set-Location $WorkEnvironmentRoot
```

Copy [local.paths.example.json](../templates/local.paths.example.json) to
`local/local.paths.json`, then set `work_environment_root`, `skills_root`, and
only the repo paths you intend to validate. Never commit the local copy.

Choose the skill directory used by your agent. For Codex this is normally:

```powershell
$SkillRoot = if ($env:CODEX_HOME) {
  Join-Path $env:CODEX_HOME "skills"
} else {
  Join-Path $env:USERPROFILE ".codex\skills"
}
```

## 2. Verify The Source Before Installation

Run the public boundary and template checks:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-SkillTemplates.ps1
```

The installer refuses a write from a dirty worktree by default. That makes an
installation reproducible from the recorded commit. `-AllowDirtySource` is
available for deliberate local development only; the generated provenance then
records `source_worktree_dirty: true`.

## 3. Plan, Install, And Verify

Planning is read-only:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Plan
```

Review all five rows, then install. Writes require `-Execute`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Install `
  -Execute
```

Verify managed hashes and the local locator:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Verify
```

Use `-SkillId <skill-name>` to operate on one or more selected skills. Use
`-Json` when another tool needs structured results.

Each installed skill receives:

- `.morphospace-skill-source.json`: skill id, source repo/commit/release,
  dirty-source state, managed-file hashes, and aggregate source fingerprint;
- `references/local-work-environment.json`: the exact local clone and docs root.

Those files are local installation records. Do not copy them back into this
public repository.

## 4. Configure Each Router

The installed routers use the same locator, but their external prerequisites
differ.

### rusty-morphospace

Use this as the portable first-hop router for public architecture, ownership,
composition, activation, source locks, work-unit lifecycle, validation,
boundary, and instruction-routing questions. It is eligible for implicit use
and contains no machine paths or live state.

### rusty-morphospace-context

Invoke this resolver explicitly when a task needs the installed
work-environment clone. It reads the generated locator, then hands portable
guidance to `rusty-morphospace`. Its `agents/openai.yaml` keeps
`allow_implicit_invocation: false`; it contains no architecture copy, live
unit, or release-candidate status. Private planning workspaces may add a
stricter state-first read order in their own `AGENTS.md`.

### system-engineering

No machine-specific rewrite is required. The local locator resolves the
work-environment contracts, while project/repo instructions define the current
authority and validation surfaces. Keep project-specific architecture memory in
the project, not in the managed skill file.

### rust-work-graph

The router itself needs no generated graph database. Configure any optional
graph tool separately, keep its outputs outside the skill directory, and derive
scan scope from the current unit. A tracked-file inventory is the safe default.

### meta-quest-workflow

Clone the public `meta-quest-agent-workflow` repo only when Quest work is in
scope and record its path in the ignored local configuration. The skill routes
device operations there; this work-environment repo does not bundle ADB, SDKs,
Meta tools, device serials, or a competing headset procedure. Installing the
skill does not authorize device mutation or require a connected headset.

For the routine local ecosystem loop, copy
`templates/quest-file-manager-cli.example.json` to the ignored
`local/quest-file-manager-cli.json`. Pin the exact CLI SHA-256, semantic
version, and source revision, then run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Resolve-QuestFileManagerCli.ps1 `
  -ConfigPath .\local\quest-file-manager-cli.json `
  -Json
```

The resolver is target-free and read-only. It verifies the configured
executable hash, product/version/source identity, release signature when
applicable, and the required inspected-deployment/Kiosk help routes. It does
not discover a headset, approve an operation, establish Fleet authority, or
authorize fallback.

## 5. Update An Existing Installation

First inspect and verify:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Plan

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Verify
```

An existing directory without provenance is reported as unmanaged and is never
overwritten by `Install`. Review it, then opt into a managed update:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -TargetRoot $SkillRoot `
  -Action Update `
  -SkillId rusty-morphospace-context `
  -Execute
```

Before replacement, the updater copies the complete existing skill directory
to `<skill-root>-backups/<utc-stamp>/<skill-id>/`. It overwrites only files
managed by the portable source and preserves additional local files. A source
file edited locally is managed drift and will be restored by Update; keep local
notes in separate files or project/repo instructions.

After review, repeat Update for the remaining named skills or omit `-SkillId`
to update all five. Run Verify again.

## 6. Recovery And Removal

If an update is unsuitable, stop the agent, compare the timestamped backup with
the installed directory, and restore only the intended skill. Do not merge old
transient roadmap state back into `rusty-morphospace-context`.

The installer does not provide an uninstall action and never deletes a skill
directory. Removal is a separate user-owned decision.

## 7. Bootstrap Regression Test

Maintainers can validate the complete lifecycle in an isolated temporary root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-LocalSkillBootstrap.ps1
```

The test proves plan/install/verify behavior, drift detection, explicit update,
backup creation, unmanaged-file preservation, and final verification for all
five skills without touching the contributor's real skill directory.
