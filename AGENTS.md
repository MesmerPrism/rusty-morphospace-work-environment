# Agent Notes

This repository owns portable workflow contracts, schemas, examples, validators,
and skill templates. Each project owns its instantiated `morphospace/` state.
Keep live state, private evidence, and machine paths in the project or ignored
local configuration; do not copy them here.

## Always apply

- Keep committed content public and portable. Use placeholders in public docs;
  keep paths, repository names, device serials, package identities, credentials,
  pairing material, logs, screenshots, APKs, and private payloads in ignored
  `local/` or `artifacts/` locations.
- Use PowerShell 7.6 LTS or newer through `pwsh` for authoritative workflows,
  child runners, validation, and examples. Windows PowerShell 5.1 is only for
  bootstrap detection; do not add new `powershell.exe` execution paths.
- Preserve unrelated dirty work. Inspection and planning are non-mutating;
  execution, validation, acceptance, publication, and device evidence are
  distinct owner authorities. An active scoped task continues through already
  authorized read-only or recoverable work; stop only at a real authority,
  safety, scope, or evidence boundary.
- Production declaration aliases exist only in the versioned lifecycle
  `change_category_aliases` map. They map one-to-one to canonical categories
  and never relabel accepted evidence.
- Keep `AGENTS.md` and `SKILL.md` as routing indexes. Put long procedures in
  linked owner docs, and synchronize affected instructions before acceptance.

## Route the task

Use the installed local routers:

- `$rusty-morphospace` for normal architecture, ownership, composition,
  workflow, validation, and instruction routing. It resolves the installed
  locator directly.
- `$rusty-morphospace-context` only for existing callers needing the
  compatibility locator.
- `$system-engineering` for authority, contracts, interfaces, observability,
  and validation design.
- `$rust-work-graph` for bounded inventories, source roots, and impact maps.
- `$meta-quest-workflow` before live Quest, ADB, APK, launch, capture, logcat,
  Perfetto, Wi-Fi ADB, or Meta tooling work. This repository never owns a
  competing device procedure.

Install or update local routers only through
[Local Skill Bootstrap](docs/LOCAL_SKILL_BOOTSTRAP.md) and
`scripts/Install-LocalSkills.ps1`. Managed writes require `-Execute`; updates
back up managed content and preserve unmanaged files. The canonical Meta skill
comes only from an explicit clean `meta-quest-agent-workflow` checkout.

## Choose the governing contract

Read only the documents that match the requested work; their exact contracts
remain authoritative.

| Work | Read |
| --- | --- |
| Project composition, module extraction, activation, and isolation | [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md), [Module Lifecycle](docs/MODULE_LIFECYCLE.md), [Feature Activation](docs/FEATURE_ACTIVATION.md), [Project Isolation](docs/PROJECT_ISOLATION.md) |
| Iteration lifecycle, scoped work, hosted observation, transactions, and recovery | [Autonomous Iteration](docs/AUTONOMOUS_ITERATION.md) |
| Ordinary continuation from adopted history | [Current Work Validation](docs/CURRENT_WORK_VALIDATION.md) |
| Validation selection, affected checks, and evidence | [Validation](docs/VALIDATION.md), [Affected Validation](docs/AFFECTED_VALIDATION.md) |
| Validator, policy, runner, or schema trust-root change | [External Validation Authority](docs/EXTERNAL_VALIDATION_AUTHORITY.md) |
| Repository lifecycle, source-only publication, or planned publication accounting | [Repository Lifecycle](docs/REPOSITORY_LIFECYCLE.md), [Source-Only Publication](docs/SOURCE_ONLY_PUBLICATION.md), [Planned Publication Accounting](docs/PLANNED_PUBLICATION_ACCOUNTING.md) |
| Published or unpublished planning-authority recovery | [External Planning and Historical Reconstruction](docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md), [Unpublished Planning Authority Materialization](docs/UNPUBLISHED_PLANNING_AUTHORITY_MATERIALIZATION.md) |
| Explicit historical audit or compatibility migration | [Historical Unit Adoption](docs/HISTORICAL_UNIT_ADOPTION.md), [Historical Supersession Compatibility](docs/HISTORICAL_SUPERSESSION_COMPATIBILITY.md) |
| Live Quest package or evidence work | [Quest APK Workflow](docs/QUEST_APK_WORKFLOW.md), then `$meta-quest-workflow` |
| Instruction, router, or skill impact | [Instruction Synchronization](docs/INSTRUCTION_SYNCHRONIZATION.md) |

Ordinary continuation uses the accepted current-work boundary. It keeps current
units, authenticated transaction suffixes, explicit prerequisites, source locks,
and scope strict; it does not retrofit newer requirements onto retired units.
Use `-CurrentWorkOnly -SkipOwnerSelfTests` only for an unchanged adopted
consumer. Historical recovery is an explicit route and preserves retained bytes.

For concurrent work, bind each source, build, and run to its declared exact
identity. A closed feature lock controls activation; selection alone does not
activate a runtime. Keep reusable modules behind an independent consumer or
neutral conformance harness. Keep UI, CLI, platform, and device adapters out of
their reusable authority owners.

## Authority and publication

One owner controls each runtime parameter and state transition. Adapter
readback proves transport, while acceptance requires the consuming owner’s
effective marker or receipt. Keep control planes separate from high-rate media,
pose, depth, mesh, camera, particle, and GPU-buffer data. A validation pass,
acceptance, publication, and device run remain separate facts.

Use exact synchronized readback only for an unchanged declared repository with
equal revisions, clean state, zero commits, bound identity/order, and an
explicit no-acceptance claim. Treat planned and source-only publication,
intervening accepted publication, externally published planning authority, and
historical reconstruction as their named owner contracts; none grants a general
remote-drift, chronology-repair, Git-mutation, or publication exception.

Before expensive package, signer, grant, toolchain, or bridge work, consume a
hash-bound project-produced preflight observation. It is admission evidence,
not build, device, validation, acceptance, or publication authority.

## Validate proportionately

Run focused owner checks while editing. Before a work-environment commit, use
the Quick checkpoint in [Validation](docs/VALIDATION.md), `git diff --check`,
and the named owner self-test for the changed contract. Run Standard delta only
after Quick when its boundary requires it; use Deep only for its declared
authority risk. A device is not part of these tiers.

Use the exact instruction-synchronization route for changes to authority,
module layout, activation, validation, device policy, repository routing, or
public/private boundaries. Update only the declared affected surfaces. Do not
run legacy scans or resolve legacy material unless the task explicitly selects
historical or legacy work.
