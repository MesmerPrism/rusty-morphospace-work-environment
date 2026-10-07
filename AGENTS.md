# Agent Notes

This repository owns portable workflow contracts, schemas, validators and skill
templates. Projects own their instantiated `morphospace/` state. Keep committed
content public and portable; private evidence, machine paths, credentials,
device identities and generated artifacts belong in ignored local storage.

## Continue the requested work

Use the nearest owner instructions and the documents for the effect being
changed. For a bounded implementation or documentation change, use
[Direct Work Packages](docs/DIRECT_WORK_PACKAGES.md). For ordinary continuation,
start with [Current Work Validation](docs/CURRENT_WORK_VALIDATION.md); read
historical recovery only when selected or required by an actual current error.

Continue already authorized work and recoverable repairs through completion.
Ask only about a real unresolved scope, authority, safety or evidence boundary;
stop the dependent action and continue independent work. An explicitly active
[Full Authority Mode](docs/FULL_AUTHORITY_MODE.md) supplies task-scoped delegation,
not a substitute for owner contracts or exact evidence.

Preserve unrelated dirty work and immutable accepted history. Use `pwsh` 7.6 LTS
or newer for authoritative workflows and child runners; Windows PowerShell 5.1
is bootstrap detection only. A validation pass, acceptance, publication and device
run remain separate facts.

## Route only the relevant concern

- `$rusty-morphospace`: normal first hop; resolves its installed locator directly.
- `$system-engineering`: authority, contracts, interfaces and validation design.
- `$rust-work-graph`: bounded source, dependency and instruction inventories.
- `$meta-quest-workflow`: live Quest/ADB/APK/launch/capture/Meta work; this repo
  owns no competing device procedure.
- `$rusty-morphospace-context`: compatibility locator for existing callers.
- `$rusty-morphospace-cleanup`: user-requested manual cleanup; never schedule it.

Install/update managed routers through [Local Skill Bootstrap](docs/LOCAL_SKILL_BOOTSTRAP.md)
and `scripts/Install-LocalSkills.ps1`: writes require `-Execute`, updates back up
managed bytes and preserve unmanaged files. Canonical Meta source comes from an
explicit clean `meta-quest-agent-workflow` checkout.

## Select the owner contract

Read the matching row, rather than every document in this table.

| Work | Read |
| --- | --- |
| Project composition, module extraction, activation, and isolation | [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md), [Module Lifecycle](docs/MODULE_LIFECYCLE.md), [Feature Activation](docs/FEATURE_ACTIVATION.md), [Project Isolation](docs/PROJECT_ISOLATION.md) |
| Lifecycle, active envelope extension, or tooling upgrade | [Autonomous Iteration](docs/AUTONOMOUS_ITERATION.md), [Active Development Envelope Extension](docs/ACTIVE_DEVELOPMENT_ENVELOPE_EXTENSION.md), [Tooling Context](docs/TOOLING_CONTEXT.md) |
| Ordinary continuation from adopted history | [Current Work Validation](docs/CURRENT_WORK_VALIDATION.md) |
| Validation selection, affected checks, and evidence | [Validation](docs/VALIDATION.md), [Affected Validation](docs/AFFECTED_VALIDATION.md) |
| Validator, policy, runner, or schema trust-root change | [External Validation Authority](docs/EXTERNAL_VALIDATION_AUTHORITY.md) |
| Explicit standing user delegation to the current agent | [Full Authority Mode](docs/FULL_AUTHORITY_MODE.md) |
| Repository lifecycle, source-only publication, or planned publication accounting | [Repository Lifecycle](docs/REPOSITORY_LIFECYCLE.md), [Source-Only Publication](docs/SOURCE_ONLY_PUBLICATION.md), [Planned Publication Accounting](docs/PLANNED_PUBLICATION_ACCOUNTING.md) |
| Accepted validation artifacts placed outside ignored local storage | [Accepted Validation Evidence Relocation](docs/ACCEPTED_VALIDATION_EVIDENCE_RELOCATION.md) |
| Manual cleanup of task-owned scratch | [Direct Work Packages](docs/DIRECT_WORK_PACKAGES.md#manual-task-owned-scratch-cleanup) |
| Published or unpublished planning-authority recovery | [External Planning and Historical Reconstruction](docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md), [Unpublished Planning Authority Materialization](docs/UNPUBLISHED_PLANNING_AUTHORITY_MATERIALIZATION.md) |
| Explicit historical audit or compatibility migration | [Historical Unit Adoption](docs/HISTORICAL_UNIT_ADOPTION.md), [Historical Supersession Compatibility](docs/HISTORICAL_SUPERSESSION_COMPATIBILITY.md) |
| Live Quest package or evidence work | [Quest APK Workflow](docs/QUEST_APK_WORKFLOW.md), then `$meta-quest-workflow` |
| Instruction, router, or skill impact | [Instruction Synchronization](docs/INSTRUCTION_SYNCHRONIZATION.md) |


For fresh work in an idle project, use [Development Envelope Preparation](docs/DEVELOPMENT_ENVELOPE_PREPARATION.md)
and [Development Unit Admission](docs/DEVELOPMENT_UNIT_ADMISSION.md), including
exact roots and any retained proposed-unit retirement. A closed feature lock
controls activation; selection alone does not activate a runtime. Bind concurrent
source, build and run work to exact identities.

One owner controls each runtime parameter/state transition. Keep high-rate media
out of control messages and device adapters out of reusable authorities. UI and
typed CLI/local API share the app command handler and effective readback.
Reusable modules need an independent consumer or conformance harness.

Publication and recovery use their named contracts in the table. Exact
synchronized readback is only the unchanged, clean, equal-revision, zero-commit
route with bound identity/order and an explicit no-acceptance claim. A hash-bound
project preflight precedes expensive package/signer/grant/toolchain/bridge work;
it supplies admission evidence only.

## Validate the changed behavior

Run focused affected checks and `git diff --check` while editing. Commit one
coherent candidate, then select exact base/head using `Resolve-AffectedValidation.ps1`
and run `Invoke-AffectedValidation.ps1` on the declared host. Inspect effective
tier, selected checks, reasons and budgets in [Validation](docs/VALIDATION.md).
Tiers describe coverage, not latency; device work has its separate owner route.

Reuse finalized exact evidence when relevant inputs are unchanged. Changed owner
tooling requires its own conformance and final CI; unchanged consumers use the
current-work modes documented above. Do not repeat unrelated passing tests or
apply newer policy to retired units merely to continue current work.

[Instruction Synchronization](docs/INSTRUCTION_SYNCHRONIZATION.md) selects the
smallest relevant surfaces for review; edit only guidance whose decision changed.
Keep entrypoints as maps and procedures in owner docs. Production aliases belong
only to the versioned lifecycle `change_category_aliases` map and never relabel
accepted evidence. Each tracked path needs one affected owner and a specialized
consumer beyond `public-boundary`; preserve focused aggregate parity and freeze
before the [exact-HEAD ownership audit](docs/AFFECTED_VALIDATION.md).
