# Source-only publication

Use `PrepareSourceOnlyPublication` and `RecordSourceOnlyPublication` when an
accepted `integration-batch` development integration or snapshot must publish
its source repositories but the distinct planning owner intentionally has no
remote. This is an ordinary two-phase publication mode, not recovery.

The plan binds an authenticated accepted owner transition, its schema-valid
passing validation receipt and checkpoint, and each candidate to that receipt's
repository revision snapshot. It also binds the clean local-only planning owner,
exact source repository coverage, remote URL and protected target ref, ordered
old/candidate commits and trees, complete reviewed snapshot paths, and rollback
targets. Trigger-unit paths, when present, stay within the accepted unit's
write scope; carried paths stay within the exact project owner scope. A
carried-only row is valid only when its full candidate diff remains bound to
the accepted validation snapshot.

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
