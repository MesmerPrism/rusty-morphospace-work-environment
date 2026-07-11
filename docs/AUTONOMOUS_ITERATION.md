# Autonomous Iteration

This protocol lets an agent continue a project safely across sessions without
turning a broad roadmap into unrestricted edit authority.

## Work Unit

Every implementation slice has one `iteration-unit` record containing:

- objective and prerequisites;
- stable workflow change categories plus optional project-specific `tags`;
- allowed repositories and narrower allowed paths;
- explicit non-scope;
- acceptance proofs and validation commands;
- risk tier and device requirement;
- expected outputs;
- commit policy and push checkpoint;
- change categories and instruction impact;
- affected `AGENTS.md`, README/router, and skill surfaces, or an explicit
  reason that no instruction surface changes.

An agent may reduce scope while working. It may not expand scope beyond the
project spec and unit without a reviewed unit update.

Use `change_categories` only for portable routing and instruction-impact
semantics. Preserve domain detail such as `peer-mesh`, `binder`, or
`contract-extraction` in `tags`; do not grow the portable category registry for
each application-specific noun.

## Unit State Machine

```text
proposed -> ready -> active -> validating -> accepted
                         |          |
                         +-> blocked+
                         +-> superseded
```

At most one unit is in flight (`active` or `validating`) in a project
workspace. A blocked unit records the condition, checks attempted, and the
user or external event needed to resume. Work may continue on a different
ready unit only after workspace state is updated so there is still one current
authority.

## Instruction Synchronization

Units changing authority, module layout, feature activation, validation,
device policy, repo routing, or the public/private boundary have required
instruction impact. They cannot become `accepted` until the nearest touched
repo `AGENTS.md`, a README or router doc, and relevant skills are updated and
validated.

For an implementation-only unit with no instruction change, use
`instruction_impact: none`, leave `instruction_surfaces` empty, and record a
specific justification. See
[Instruction Synchronization](INSTRUCTION_SYNCHRONIZATION.md) for the routing
matrix. Keep entrypoints short and move detailed recipes into linked docs.

## Compact State And Event Log

`workspace.state.json` names:

- plan revision;
- current and next-ready units;
- last event;
- dirty repositories;
- blockers;
- last validation checkpoint;
- pending coordinated-push bundle.

`iteration-events.jsonl` is append-only. Add a compact record after a state
transition, contract decision, extraction, validation result, commit, push,
promotion, or blocker change. Large logs and device artifacts remain outside
the event file; events point to sanitized receipt IDs or artifact types.

## Validation Tiers

| Tier | Use | Typical evidence |
| --- | --- | --- |
| `quick` | During a small edit. | Parsing, focused unit tests, whitespace, compact-state checks. |
| `standard` | Before a local checkpoint commit. | Touched-repo checks, contract fixtures, dependency and public-boundary gates. |
| `deep` | Before a coordinated push or promotion. | Full repo checks, graph/inventory refresh where relevant, cross-consumer and integration evidence. |

Live headset work is a separate device gate. A source-only unit must not claim
device acceptance.

## Git Checkpoint Policy

- Inspect status and upstream state before editing every repository in scope.
- Commit coherent, validated slices locally; do not wait for one enormous
  cross-repo commit.
- Do not mix unrelated projects or untracked user work into a unit.
- Push only at the unit's declared checkpoint: `none`, `local-only`,
  `integration-batch`, or `release`.
- An `integration-batch` may collect several accepted units. Before pushing,
  run the deep gates named by those units and create one coordinated receipt
  listing repositories, branches, commits, validation, and rollback points.
- Update workspace state and append a push event only after the push succeeds.
- Do not accept a unit with unresolved required instruction surfaces.

The protocol supports larger push intervals without losing local commit
history or resumption evidence.

## Multi-Repository Changes

A unit names every repository it may change. Contracts land before or with
their adapters. A coordinated receipt records dependency order and confirms
that each repository is clean or intentionally dirty afterward. One repo's
successful push is not proof that the whole batch is complete.

## Optional Automation CLI

`scripts/Invoke-WorkUnitAutomation.ps1` is the portable owner for mechanical
work-unit transitions and preparation artifacts. It supports `Inspect`,
`Claim`, `Resume`, `BeginValidation`, `RecordValidation`, `Accept`,
`PreparePush`, and `Recover`.

The CLI is deliberately narrower than an autonomous coding agent:

- inspection and plans are the default; state changes require `-Execute`;
- it reads Git state but never runs checkout, reset, stash, commit, push, or
  force-push;
- it never runs validation commands or device commands;
- a required device unit cannot enter validation without explicit serials;
- acceptance is separate from recording a passing validation receipt;
- push preparation requires exact HEAD revisions, clean attached branches,
  and no behind or divergent upstream state;
- a prepared push bundle records source-first and planning-last order but has
  `execution: not-performed` and `force_push_allowed: false`.

Keep the local repository map outside a public project instance when its paths
identify a workstation. Start from `templates/repository-map.example.json`.
Supply exact revisions through `templates/revision-set.example.json` only
after the relevant validation has passed.

Inspection example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action Inspect `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map>
```

Explicit claim example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action Claim `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -OutPath <project-root>\morphospace\receipts\<claim-receipt>.json `
  -Execute
```

Every action returns a validation matrix, a graph scope limited to the unit's
declared repositories and paths, and a repository-preservation report.
`Recover` only repairs an unambiguous stale current-unit pointer; it preserves
blockers and prior validation evidence. `Resume` is the explicit transition
out of `blocked`.

## Stop Conditions

Stop and record a blocker when:

- required work is outside allowed repositories or paths;
- an authority or public/private boundary is unclear;
- a feature would become active without a descriptor and effective receipt;
- a stable promotion lacks a second consumer or conformance harness;
- validation would require unapproved device mutation or external authority;
- existing user changes overlap the unit and cannot be preserved safely.

Run `scripts/Test-WorkUnitAutomation.ps1` after changing automation behavior.
Its temporary repositories exercise clean, dirty, untracked, detached, ahead,
divergent, blocked, resumed, and interrupted states and verify that push
preparation never changes a remote.
