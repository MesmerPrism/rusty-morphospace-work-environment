# Prepared Push Retirement

Retirement is valid only when at least one distinct prepared revision is not
ancestor-or-equal to its current intended remote ref. If all are reachable,
use [Prepared Publication Reconstruction](PREPARED_PUBLICATION_RECONSTRUCTION.md).
Legacy `application`, `adapter`, `source`, and `planning` roles are accepted;
all non-planning roles are source-like. A planning leg that aliases a
non-planning physical ref is observed once and receives the stricter
source-like rule.

Retained historical `PreparePush` members are validated only through the
additive `legacy-embedded-push-bundle-plan-v1` compatibility schema. It accepts
the preserved legacy role vocabulary and the historical nullable
`publication_ordering_interruption` field, while retaining strict required
identity, ordering, ref, execution, and no-force fields and rejecting unknown
or expanded shapes. Current plan production remains governed by the pinned
`push-bundle-plan.schema.json`; this compatibility check cannot declare or
rewrite a current plan.

`rusty.morphospace.workflow.prepared_push_retirement.v1` is an additive
post-0.6.0 candidate for consuming one exact pending push bundle whose immutable
plan still records `execution: not-performed` and `force_push_allowed: false`.
It is not publication accounting, proof that publication was historically
impossible, remote-drift tolerance, or an alternative closure for an executed
push.

The receipt binds the project, bundle, complete unit set, and one reason:
`superseded`, `obsolete-composition`, or `reprepared`. Legacy preparation
provenance binds the immutable executed `PreparePush` automation receipt by
workspace-relative path and SHA-256 with member `push_plan`. It also binds the
original preparation event through the exact transition-ledger intent and
completion containers, their hashes, event identity, and member `event`.
Validators read those embedded members; they never reconstruct standalone
copies.

Every planned repository must appear exactly once in the plan, pending compact
state, repository map, and retirement observation. Validation requires the
planned branch and upstream, resolved prepared revision, current local HEAD,
fresh remote branch readback, clean attached worktree, no behind/divergent
state, and two stable observation passes. Source HEAD remains the prepared
revision. A planning HEAD may contain only the exact preparation evidence
suffix. If a prepared ahead revision is remotely reachable, retirement rejects
and the appropriate publication-accounting route remains authoritative.

The validator searches the complete workspace `receipts/` tree and event log
for workflow-recognized execution, planned accounting, reconciliation,
unplanned publication, and rewrite-recovery bindings to the bundle. Any match,
malformed searched JSON, failed remote lookup, stale readback, missing
repository, partial set, tampering, unrelated suffix, dirty state, or consumed
bundle rejects.

The portable receipt is authored outside the planning worktree so its own bytes
do not create a circular clean-state observation. Dry run validates it without
mutation. Execution copies those exact bytes to the requested top-level
`receipts/` path, records their SHA-256 in optional compact state
`prepared_push_retirements`, clears only the matching `pending_push_bundle`,
optionally clears exactly one blocker named by `mutation.blocker_id`, updates
`last_event_id`, and appends a `prepared-push-retired` transition through the
existing transaction ledger. Unit files, validation, acceptance, source Git,
remotes, devices, tags, and release history remain unchanged.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action RetirePreparedPush `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <repository-map> `
  -PreparedPushRetirement <retirement-receipt-input> `
  -OutPath <project-root>\morphospace\receipts\<retirement-receipt>.json `
  -Execute
```

Omit `-Execute` and `-OutPath` for preview. A repeated consume fails because
the exact pending bundle no longer exists.
