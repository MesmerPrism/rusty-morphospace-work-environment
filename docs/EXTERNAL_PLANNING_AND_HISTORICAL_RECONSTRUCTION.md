# External Planning Projection And Historical Reconstruction

These recovery contracts preserve damaged chronology without rewriting source
workflow history.

## Embedded workspace projection

Use `planning_workspace_projection.v1` only when source publication preceded
moving an embedded `morphospace/` workspace to distinct external planning. It
reads every workspace byte from the exact published Git tree, writes a
no-overwrite copy below a different planning repository, and records an
ordinal mode/size/SHA-256 inventory. It explicitly infers no preparation,
executed push, planning-last order, source acceptance, or Git execution.
The projected tree contains those exact source bytes plus one separately
declared projection-record path; live validation rejects every other additive
file, missing file, reparse point, or workspace-path mismatch.

```powershell
pwsh -NoProfile -File .\scripts\New-ExternalPlanningWorkspace.ps1 `
  -SourceRepository <source-repo> -PlanningRepository <planning-repo> `
  -WorkspaceRoot <planning-repo>\<project>\morphospace `
  -ProjectionPath <planning-repo>\<project>\morphospace\receipts\<projection>.json `
  -ProjectionId <projection-id> -ProjectId <project-id> -UnitId <accepted-unit> `
  -SourceRepoId <source-id> -PlanningRepoId <planning-id> `
  -Branch <source-branch> -Upstream <remote>/<branch> `
  -OldRevision <old> -PublishedRevision <published> -Execute
```

The tool performs no Git operation. Publish the exact projection through an
independently authorized planning-repository workflow. Then create
`unplanned_publication_closure.v2`, bind the projection path/hash, and run
`ReconcilePublication` from the external workspace. V2 revalidates the source
tree against the projected bytes while admitting only the exact bound closure
receipt as additive transition evidence. The embedded copy is historical until
that one-time reconciliation makes the external workspace authoritative; no
workflow transition may write the source copy.

Never use v1 closure for this migration. Never copy a dirty worktree.

## Published embedded authority adoption

Use `planning_workspace_projection.v2` instead of v1 when the exact published
embedded state has null `current_unit`, `next_ready_unit`, and
`pending_push_bundle`, but still names the source repository as dirty and
contains a stale source entry in `repository_heads`. V2 binds that exact
published state, including the complete dirty-repository set and stale
head/branch/dirty-fingerprint row:

```powershell
pwsh -NoProfile -File .\scripts\New-ExternalPlanningWorkspace.ps1 `
  -SourceRepository <source-repo> -PlanningRepository <planning-repo> `
  -WorkspaceRoot <planning-repo>\<project>\morphospace `
  -ProjectionPath <planning-repo>\<project>\morphospace\receipts\<projection>.json `
  -ProjectionId <projection-id> -ProjectId <project-id> -UnitId <accepted-unit> `
  -SourceRepoId <source-id> -PlanningRepoId <planning-id> `
  -Branch <source-branch> -Upstream <remote>/<branch> `
  -OldRevision <pre-publication> -PublishedRevision <published> `
  -ProjectionVersion v2 -Execute
```

After independently recording the exact passing source validation and observer
evidence, create a `published_planning_authority_adoption.v1` receipt and run
`AdoptPublishedPlanningAuthority` from the external workspace. The live
validator requires the source checkout to be clean, attached, synchronized,
and exact at the published remote readback. The distinct planning repository
is local-only and must remain attached at the exact receipt-bound base revision
and tree. Its unrelated worktree must be clean; only the receipt-bound
projection and adoption evidence may remain as exact workspace changes before
the transition.

The transition changes only the external workspace: it removes the named
source from `dirty_repositories`, replaces only that repository-head entry with
the synchronized head/branch and a null dirty fingerprint, appends one bound
event, and preserves blockers, registries, checkpoints, accepted evidence,
unrelated heads, and all null activity fields. It creates no plan, push
receipt, source acceptance, Git mutation, remote, force push, or history
rewrite. Repeating the adoption fails because the exact stale state no longer
exists.

`ReconcilePublication` remains the bundle-bearing recovery route. It must not
be used to invent a missing pending bundle for this null-bundle adoption case.

## Damaged historical adoption

Keep a drifted `historical_unit_adoption_receipts` path and expected hash
unchanged. Add a separately named reconstructed adoption receipt,
`historical_unit_adoption_reconstruction.v1`, and one hash-bound
`historical_unit_adoption_reconstructions` state reference. The record binds
the expected and observed hashes, the explicit
`independent-reconstruction-not-original-bytes` claim, and an immutable Git
revision/tree/path/blob anchor.

```powershell
pwsh -NoProfile -File .\scripts\Test-HistoricalUnitAdoptionReconstruction.ps1 `
  -Path <workspace>\receipts\<reconstruction-record>.json `
  -WorkspaceRoot <workspace> -AnchorRepository <source-repo>

pwsh -NoProfile -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot <workspace> `
  -RepositoryMapPath <local-repository-map>
```

The reconstruction is current-validation-only. It cannot replace the original,
rewrite acceptance, apply to current/in-flight work, or coexist with a
conflicting reconstruction. Neither contract authorizes device work, source
Git mutation, force push, or retrospective chronology.
