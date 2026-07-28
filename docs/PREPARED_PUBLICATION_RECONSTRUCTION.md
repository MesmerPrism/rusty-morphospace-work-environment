# Prepared Publication Reconstruction

`prepared_publication_reconstruction.v1` closes stale prepared-bundle
bookkeeping when every distinct prepared revision is now ancestor-or-equal to
the current intended remote ref but the immutable PreparePush owner still says
`execution: not-performed`.

Use `ReconcilePreparedPublication`; retirement instead requires at least one
distinct prepared revision to be unreachable. Planned accounting requires an
executed-push receipt, and unplanned closure requires publication before
preparation.

The input hash-binds the exact PreparePush owner and named `push_plan`, prepared
intent/completion/event, accepted unit and passing validation, canonical
pending bundle and blocker, logical legs, and collapsed physical remote/refs.
The passing validation receipt must satisfy the complete v1 schema and bind to
both its validation-pass transition and the acceptance transition that produced
the exact accepted unit bytes.

Physical refs are derived from the immutable plan plus repository map. Every
logical plan leg appears exactly once. Aliases collapse only when resolved
repository path, intended remote, intended merge ref, prepared revision,
branch, and upstream are identical; split, merged, duplicate, unused, or
substituted refs reject. Live branch, upstream, remote, and remote ref are
revalidated without making historical actor, time, order, or force claims.
Each physical ref enumerates the complete ordered `prepared..tip` history with
full revisions, parents, trees, and changed paths. Active worktrees are
non-evidentiary; Git proof comes from clean isolated readback repositories and
two fresh remote observations.

Claims about original execution, cross-repository order, planning-last
execution, force/no-force history, actor/time, and historical non-publication
are false. Execution transactionally installs the exact input bytes, clears
only matching bookkeeping, and appends `prepared-publication-reconstructed`.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action ReconcilePreparedPublication `
  -WorkspaceRoot <project-morphospace-root> `
  -UnitId <accepted-unit-id> `
  -RepoMapPath <clean-readback-repository-map.json> `
  -PreparedPublicationReconstruction <path-to-input-evidence.json> `
  -OutPath <project-morphospace-root>\receipts\<reconstruction-id>.json `
  -Execute
```
