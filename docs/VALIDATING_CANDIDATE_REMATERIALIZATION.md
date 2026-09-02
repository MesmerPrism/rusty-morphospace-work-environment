# Validating Candidate Rematerialization

`RematerializeValidatingCandidate` is a narrow recovery action for a current
development-envelope unit whose frozen product work remains byte-identical but
whose adopted source prerequisites advanced. It replaces the unit's exact
source lock and candidate-freeze marker without changing the unit's
`validating` status or claiming a validation result.

This route is not `ReturnToActive`. It requires no fabricated failure receipt,
does not discard the current unit, and does not perform Git, source, build,
device, validation, acceptance, or publication work.

## Inputs

The caller materializes, outside the workspace transaction targets:

1. one closed `source_composition_lock.v1` document produced from an explicit
   exact `-RepoId` set; and
2. one closed `candidate_freeze.v2` document produced from that lock and the
   live planning preimage.

Do not hand-author the v2 authority document. First produce the target lock
with every and only the product repositories in scope, then derive the v2
input without mutating planning or Git state:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\New-SourceCompositionLock.ps1 `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <unit-id> `
  -RepositoryMapPath <project-root>/morphospace/repository-map.json `
  -RepoId <product-repo-id> `
  > <operator-evidence-root>/target-source-lock.json

pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\New-ValidatingCandidateRematerializationInput.ps1 `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <unit-id> `
  -RepositoryMapPath <project-root>/morphospace/repository-map.json `
  -TargetSourceCompositionLock <operator-evidence-root>/target-source-lock.json `
  -FreezeId <new-freeze-id> `
  -RematerializationId <rematerialization-id> `
  -RepoId <product-repo-id> `
  -OutPath <operator-evidence-root>/candidate-freeze-v2.json
```

Repeat `-RepoId` (or pass an explicit PowerShell array) for a multi-repository
product. The exact set must equal the predecessor composition, predecessor
freeze, changed-path closure, and target lock. Extra repository-map entries do
not enter the product composition implicitly. For Morphovision, name
`morphovision-public-development` explicitly; never rely on selecting every
entry from the local map.

The v2 freeze retains every v1 candidate field. Its lineage additionally binds
the predecessor freeze and source-lock bytes, three distinct repository
identities (the source-lock baseline, frozen predecessor, and adopted target),
the complete stale normal-validation selector, raw and canonical
project/feature/state/unit CAS values, repository-map bytes, ledger
length/hash/tail, and exact carried blobs for every previously changed path.
The baseline must be an ancestor of the frozen predecessor, which must in turn
be an ancestor of the target. Carried blobs are compared from the frozen
predecessor to the target, never from the older source-lock baseline.
The rematerialization identity is limited to 119 characters so its derived
`<rematerialization-id>-recorded` event remains a valid 128-character protocol
identity; the derived identity is also checked during the dry run.

The target lock may contain exactly the predecessor product-composition
repository set. QFM and other external validation or device providers are
evidence providers, not product source-composition repositories.

All selected mapped repositories must already exist at the requested clean
commit/tree, including no untracked files.
The action observes them only through `git --no-optional-locks`, preventing
even an optional index refresh. It never fetches, checks out, resets, cleans,
or otherwise changes Git state.

Run a dry pass first and retain the returned v2-freeze input SHA-256. Execution
must supply that exact hash:

```powershell
Invoke-MorphospaceRematerializeValidatingCandidate `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <unit-id> `
  -CandidateFreeze <candidate-freeze-v2-input> `
  -SourceCompositionLock <source-composition-lock-input> `
  -RepoMapPath <project-root>/morphospace/repository-map.json `
  -OutPath <project-root>/morphospace/receipts/<freeze-id>.json

Invoke-MorphospaceRematerializeValidatingCandidate `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <unit-id> `
  -CandidateFreeze <candidate-freeze-v2-input> `
  -SourceCompositionLock <source-composition-lock-input> `
  -RepoMapPath <project-root>/morphospace/repository-map.json `
  -OutPath <project-root>/morphospace/receipts/<freeze-id>.json `
  -ExpectedCandidateFreezeSha256 <dry-run-sha256> `
  -Execute
```

The public router may expose equivalent argument names; it must pass these two
documents and the dry-run hash without modifying their bytes.

## Atomic projection

The action uses transition-ledger intent v6 with exact raw pre-state and
pre-unit hashes, canonical state/unit hashes, ledger tail, and exact raw plus
canonical preimages for the unchanged `feature.lock.json` and
`project.spec.json` projections. The transaction owns exactly two create-new
artifacts in ordinal path order:

- `receipts/<freeze-id>.json` — the exact producer-authored v2 freeze;
- `source-compositions/<lock-id>.lock.json` — the exact producer-authored source
  lock.

It changes only:

- the unit's `source_composition` marker;
- the unit's `candidate_freeze` marker;
- `workspace.state.normal_validation_selection`, from the exact bound stale
  selector to `null`;
- `last_event_id` and one appended state-transition event; and
- exactly one existing repository-head row for each writable predecessor. The
  complete predecessor row (`head`, `branch`, and the canonical SHA-256 of
  empty status porcelain, `e3b0c442...b855`, as `dirty_fingerprint`) is bound
  and replaced by the complete target row carrying that same canonical clean
  fingerprint and observed from the clean mapped repository. `null` and any
  non-empty-status fingerprint reject before projection.

The current unit, `validating` status, validation checkpoint, blockers, pending
state, work scope, instruction surfaces, validation/acceptance declarations,
and all unrelated unit/state fields remain unchanged. An extant passing
validation checkpoint or pending publication bundle rejects the initial
transition.

## Recovery and verification

Intent publication, both artifact installations, projections, event append,
and completion are independently recoverable. A retry must authenticate the
same input bytes, predecessor evidence, Git ancestry and carried blobs, exact
v6 intent and raw preimages, complete predecessor/target repository-head projections, target
reconstruction, and two artifacts before invoking ledger
repair. A completed exact retry reports
`validating-candidate-already-rematerialized`; any conflicting intent,
artifact, source lock, predecessor receipt, Git observation, live projection,
or ledger tail rejects.

`Test-MorphospaceRematerializedCandidate` is the consumer verifier. It validates
the v2 receipt and target lock schemas, immutable predecessor evidence, live
clean repository closure, ancestry and blob carryover, committed v6
intent/completion, exact current unit/state markers, artifact bytes, and the
unique physical event tail. A normal validation selector may be bound only
after this exact rematerialized candidate has passed verification.

## Non-claims

Rematerialization proves only an exact planning-side source and freeze
projection. It does not prove that source was edited by this action, that a
build or APK exists, that a device or wearer was used, that validation passed,
or that acceptance or publication is authorized.
