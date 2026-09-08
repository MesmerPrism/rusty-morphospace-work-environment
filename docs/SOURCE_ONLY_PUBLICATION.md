# Source-only publication

Use `PrepareSourceOnlyPublication` and `RecordSourceOnlyPublication` when an
accepted `integration-batch` development integration or snapshot must publish
its source repositories but the distinct planning owner intentionally has no
remote. This is an ordinary two-phase publication mode, not recovery.

## Prepare inputs through the owner interface

Use `scripts/New-SourceOnlyPublicationInput.ps1` instead of writing a
project-specific plan generator. Its actions observe Git and produce create-new
inputs; the existing automation actions retain lifecycle authority.

1. Run `-Action Readiness -WorkspaceRoot <workspace> -UnitId <unit>
   -RepoMapPath <map> -PublicationId <id> -OutPath <readiness.json>` before
   committing to this publication route. Keep that publication ID through a
   bounded network retry or interrupted preparation/recording.
2. Produce the validation receipt with `scripts/New-ValidationReceipt.ps1`,
   supplying the actual validation outcomes in `-EvidencePath`. The builder
   observes repository revisions, scoped changed paths and artifact hashes;
   it does not run tests or infer successful outcomes. Evidence contains
   `receipt_id`, `tier`, `result`, `artifacts`, `criteria`, `gates` and
   `device_validation`. Each input artifact supplies only `artifact_id`,
   `kind` and `path`; relative paths resolve from the output receipt directory.
   Record and accept through the normal owner actions.
3. Commit the accepted local planning checkpoint, rerun readiness, then use
   `-Action Plan` with the same workspace, unit, map and publication ID.
   Pass its output and SHA-256 to `PrepareSourceOnlyPublication`.
4. For each source in the plan's dependency order, use `-Action StartOperation`
   with the prepared `-PlanPath` and `-RepoId`. Perform the already-authorized
   external Git/provider operation, retain its actual outcome evidence, fetch
   the final target without moving the candidate HEAD, then use
   `-Action ObserveOperation`. Remote observation alone cannot establish that
   a particular command ran or that no force option was used.
5. Use `-Action Execution -PlanPath <prepared-plan>
   -OperationObservationPaths <ordered-observations> -RepoMapPath <map>
   -OutPath <execution.json>`. Pass the result and SHA-256 to
   `RecordSourceOnlyPublication`, then run current-work validation.

Observation requires `-OperationStartPath`, `-OperationEvidencePath` and
`-ExpectedOperationEvidenceSha256`, alongside the plan and repository map. The
operation executor supplies this compact evidence from the operation it ran:

```json
{
  "schema": "rusty.morphospace.workflow.source_only_publication_operation_evidence.v1",
  "operation_start_sha256": "<SHA-256 of the start document>",
  "provider": {"repo_id": "<planned repo ID>", "executor_id": "<operation executor>"},
  "outcome": {
    "operation_finished_at": "<actual UTC timestamp>",
    "push_mode": "fast-forward", "force_used": false, "result": "pass"
  },
  "artifact": {"path": "operation.log", "sha256": "<SHA-256 of the retained outcome>"}
}
```

Use `false` and `pass` only when the executor's actual command/provider result
establishes them. This is an explicit executor attestation, not independent
proof of execution. The builder binds it to the start document, validates its
artifact relative to the evidence directory, and separately observes the exact
planned remote, final commit, parents and tree. It rejects absent or unknown
outcomes. Keep inputs with private repository identities in private planning.

`Readiness` uses the same isolated, hash-bound Git executable and configuration
environment as the publication observations. It reports repository-local
normalization, attribute hashes and credential-helper availability without
recording credential values. It authenticates Windows physical roots and Git
common directories before reporting a supported layout. A resolver map can
include external instruction/skill support entries: `project.spec.json`
defines project membership, and the unit defines published sources and
read-only dependencies. A support entry does not become a publication target.

`supported` means the inspected layout fits this route; it is not validation,
acceptance or publication permission. `unsupported` gives the incompatible
shape before an owner transition. In particular, each published source must
have a remote delta; declare genuinely unchanged sources as read-only when
admitting the unit. `unavailable` identifies incomplete remote readback, with
any separately observed source/evidence problem retained in `reason_codes`.
Retry the readback with the existing identity; network failure alone is not a
reason to create a unit or repeat source validation.

## Bound publication contract

The plan binds an authenticated accepted owner transition, its schema-valid
passing validation receipt and checkpoint, and each candidate to that receipt's
repository revision snapshot. It also binds the clean local-only planning owner,
exact source repository coverage, remote URL and protected target ref, ordered
old/candidate commits and trees, complete reviewed snapshot paths, and rollback
targets. Trigger-unit paths, when present, stay within the accepted unit's
write scope; carried paths stay within the exact project owner scope. A
carried-only row is valid only when its full candidate diff remains bound to
the accepted validation snapshot.

The plan's acceptance receipt and validation-evidence references are
workspace-relative. Within a `validation_receipt.v1`, relative artifact paths
resolve from the receipt's directory; rooted artifact paths retain their
declared rooted resolution. Every artifact remains bound by its exact raw
SHA-256.

`fast-forward` binds the candidate as the final ref. `provider-merge` leaves
the future merge revision unset in the plan. Recording accepts it only when
the externally observed merge has exactly two ordered parents: the bound old
protected ref and bound candidate, and when its tree equals the candidate
tree. Both modes require a direct remote readback against the bound URL, clean
sources, no force, declared dependency order, reverse rollback order, and
per-source operation/readback timestamps in that order.

Keep each candidate branch tracking the plan's bound target, such as
`origin/main`. Publish a temporary feature ref explicitly with
`git push origin HEAD:refs/heads/<feature>`; do not use `git push -u`, because
retargeting the candidate's upstream changes its reviewed identity. After a
provider merges the feature ref, fetch the protected target for readback while
leaving the candidate branch and its reviewed HEAD checked out for
`RecordSourceOnlyPublication`.

Preparation writes the immutable plan, pending bundle, and event through the
transition ledger. Recording re-authenticates that exact owner transaction and
consumes only its pending bundle after remote evidence. Either action recovers
only its exact interrupted ledger transaction. The planning repository remains
local-only throughout: no remote, planning ref, or planning-publication claim
is created.

Current-work validation recognizes the exact prepared or recorded source-only
tail from its committed transition, schema-valid plan or execution artifact,
retained accepted unit, and bounded state delta. This local history check does
not repeat source remote, ordering, merge-parent, or tree observations; the
source-only writer performs those checks before it commits the transition. It
also does not require a planning transport repository or planning remote.

Run `pwsh -NoProfile -File .\scripts\Test-SourceOnlyPublication.ps1 -SelfTest`
for the focused provider-merge, replay, and prepared/recorded current-work
fixture. This check is Windows-only because source/planning alias rejection
uses volume serial and `FileIdInfo` directory identity. Its affected-validation
closure includes the transition ledger, content-observation helper, protocol
common layer, and public automation wrapper.

Also run `scripts/Test-SourceOnlyPublicationInputs.ps1 -SelfTest` when changing
the builders or their shared receipt contract. This rehearsal uses the receipt
producer and real RecordValidation, Accept, preparation and recording actions,
with local-only planning, two ordered source repositories, empty source write
scope, receipt-relative evidence, provider merges and preserved retired history.
The focused recovery suite covers every owner interruption boundary. Neither
fixture turns source publication into build, device, wearer or release evidence.
