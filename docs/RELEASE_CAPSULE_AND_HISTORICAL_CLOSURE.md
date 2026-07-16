# Release Capsules And Historical Closure

A release is an immutable set of committed Git trees. It is not a promise that
the same branch tips or contributor worktrees will remain unchanged forever.

Use `release_capsule.v1` to seal the exact commit and tree for every repository
in a coordinated release. The capsule also names the remote refs that carried
each commit at the release cut and binds the validation artifacts used for the
decision. Uncommitted overlays are always excluded.

## Two Validation Modes

`candidate-cut` is the publication-time gate. Every declared remote ref must
equal its pinned revision. When several branches are declared for one
repository, this exact check proves their convergence at the cut.

`historical-closure` is the later audit gate. Every pinned revision must still
be an ancestor of, or equal to, each declared remote ref. Later descendant
commits are expected and do not alter the sealed release. A missing ref or a
history rewrite fails closed.

Both modes clone committed objects into a temporary isolated worktree, detach
at the pinned revision, verify the pinned tree, and require that materialized
tree to be clean. The active repository is only observed. Its current branch,
HEAD, and dirty-entry count do not become release payload and are never
modified by the validator.

```powershell
# At the candidate cut
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ReleaseCapsule.ps1 `
  -Path <project-root>\morphospace\receipts\release-capsule.json `
  -RepoMapPath <project-root>\morphospace\repository-map.json `
  -Mode CandidateCut `
  -OutPath <evidence-root>\candidate-cut-receipt.json

# At any later audit
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ReleaseCapsule.ps1 `
  -Path <project-root>\morphospace\receipts\release-capsule.json `
  -RepoMapPath <project-root>\morphospace\repository-map.json `
  -Mode HistoricalClosure `
  -OutPath <evidence-root>\historical-closure-validation.json
```

The repository map is local routing only. Do not put machine paths in the
portable capsule. The capsule's `remote_url` is the publication authority;
the mapped local repository supplies already-available committed objects and
the active-worktree observation.

## Evidence Repair

Accepted events and receipts remain append-only. If a formerly bound artifact
is missing or its bytes no longer match the recorded SHA-256:

1. record `damaged-original-unavailable` with both expected and observed
   hashes;
2. derive a separate reconstruction from independent Git ref, ancestry,
   validation, or capture evidence;
3. label it `independent-reconstruction-not-original-bytes`;
4. bind both facts in a new `historical_release_closure_receipt.v1`;
5. never overwrite or relabel the damaged evidence as the original artifact.

An exact-tree graph used for historical closure must be generated from the
isolated capsule materializations, not from live worktree overlays.

## What Closure Does Not Mean

Historical closure does not validate later commits, reopen device validation,
or authorize Git mutation. If later source should ship, cut a new release
candidate and make a new version decision. Reuse earlier device evidence only
for the same pinned source subject and record that no device rerun occurred.

Run `scripts\Test-ReleaseCapsule.ps1 -SelfTest` for damaged-fixture coverage.
It proves advanced descendants and dirty active work are accepted only in the
historical model, while wrong trees, missing refs, mutated policy, receipt
tampering, and rewritten history fail closed.
