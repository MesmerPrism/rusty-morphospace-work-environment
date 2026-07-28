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
The preparation intent must own exactly one artifact: that same automation
receipt with identical path, SHA-256, and base64-decoded bytes. `PreparePush`
constructs those final bytes before starting the transition; the ledger
installs them inside the state/unit/event transaction, so a later plan-file
replacement is not admissible historical provenance.
Validators read those embedded members; they never reconstruct standalone
copies. `repository_map_sha256` binds the exact portable repository map used
for both readback passes.

Every planned repository must appear exactly once in the plan, pending compact
state, repository map, and retirement observation. Validation requires the
planned branch and upstream, resolved prepared revision, current local HEAD,
fresh remote branch readback, clean attached worktree, no behind/divergent
state, retained fetch/push endpoint identity, and two stable observation
passes. Source HEAD remains the prepared
revision. A planning HEAD may contain only the exact preparation evidence
suffix. If a prepared ahead revision is remotely reachable, retirement rejects
and the appropriate publication-accounting route remains authoritative.
Every Git graph read disables replacement objects and rejects replacement refs,
grafts, shallow history, alternates, external object storage, linked Git
ownership, and `GIT_*` overrides. Physical directory identity—not textual path
casing—defines aliased repository groups, and fetch/push endpoints must resolve
to one stable identity.

The validator searches the complete workspace `receipts/` tree and a bounded,
strict-UTF-8, duplicate-key-rejecting event log
for workflow-recognized execution, planned accounting, reconciliation,
unplanned publication, rewrite-recovery, competing reconstruction/retirement,
or their consuming automation bindings to the bundle. Every event receipt is
resolved and parsed even when its event is not a push; empty-receipt push
events reject. When the current portable retirement input already resides
under this workspace's `receipts/` tree, only that exact input path is excluded
from the conflict scan so the candidate does not conflict with itself; a
distinct retirement or other recognized competitor remains a conflict. Any match,
malformed searched JSON, failed remote lookup, stale readback, missing
repository, partial set, tampering, unrelated suffix, dirty state, or consumed
bundle rejects.

The portable receipt is authored outside the planning worktree so its own bytes
do not create a circular clean-state observation. Dry run validates it without
mutation. Execution copies those exact bytes to the requested top-level
`receipts/` path and binds that path, SHA-256, and byte payload through the
transition intent artifact, event receipt reference, and committed completion.
The compact workspace-state schema has no `prepared_push_retirements`
projection. Execution clears only the matching `pending_push_bundle`,
optionally clears exactly one blocker named by `mutation.blocker_id`, updates
`last_event_id`, and appends a `prepared-push-retired` transition through the
existing transaction ledger. Unit files, validation, acceptance, source Git,
remotes, devices, tags, and release history remain unchanged.
Input, bound preparation evidence, and the repository map are read once into
bounded strict-JSON snapshots and retained under read leases. Execution repeats
their exact-byte checks, state/unit/specification CAS, strict ledger and
conflict scans, output absence, and the complete Git readback under the
workspace transaction mutex before installing the retained input bytes.
`stale_blocker` remains mandatory even when `mutation.blocker_id` is `null`:
in that shape it is a canonical observation of the live stale blocker, not
authority to remove it. A null mutation retires only the pending bundle and
preserves that blocker plus every unrelated blocker. A non-null mutation must
equal the observed stale blocker ID exactly.

The original preparation owner is accepted only when its canonical transaction
paths, intent targets, completion hashes, exact event bytes, and preceding
event tail authenticate to one entry in the strict append-only event ledger.
The current workspace-state `last_event_id` must equal that ledger's tail both
before validation and again under the execution mutex; retirement never heals
a pre-existing split authority.

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
the exact pending bundle no longer exists unless the same executed call is
resuming its deterministic transaction. Before applying ordinary output-exists
or consumed-bundle rejection, an executed retry authenticates the exact current
retirement-input bytes, repository-map bytes, unit, retained output path,
transition intent, target state/unit, event identity, and optional committed
completion. It repairs an interrupted intent through the transition ledger or
returns the already-committed result. Any changed input, path, unit, target,
artifact, event, or completion fails closed rather than becoming a second
retirement.
