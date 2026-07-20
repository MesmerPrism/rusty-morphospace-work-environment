# Planned Publication Accounting

An unchanged declared source repository may use additive
`synchronized_readback` accounting only when the prepared, old, final, and
remote-readback revisions are identical, the executed receipt says
`readback-only`, the repository is clean with zero commits, and its triggering
unit carries `no_acceptance_claim: true`. Identity, branch/upstream, order, and
status evidence remain exact. Changed repositories still require complete
commit and changed-path attribution.

If that immutable readback-only execution is followed by a separately
validated and accepted workflow correction, the additive
`intervening_accepted_publication` recovery binds the execution-time final and
readback separately from the current clean remote-exact final. It requires
fast-forward ancestry, the complete ordered commit/path range, accepted unit
and passing validation evidence, and source-first/planning-last recovery
chronology. Planning commits without a unit are admitted only as explicitly
typed blocker or publication-finalization evidence whose paths equal a narrow
allowlist. The old readback leg still infers no mutation or acceptance; the
later unit is accounted independently. Normal changed-source enumeration and
the immutable prepared/executed evidence remain unchanged.

`planned_publication_accounting.v1` is the sole portable evidence accepted by
`RecordPublication` after an externally executed, previously prepared push.
It is accounting evidence, not push authority and not acceptance evidence.

The receipt binds the pending bundle, triggering unit, immutable prepared plan
and prepare event, executed-push receipt, monotonic chronology, dependency and
execution order, and the exact old-exclusive through final-inclusive commit
sequence for every repository. Every source commit is attributed to the
triggering unit or a carried unit. A carried unit binds its status evidence and
must explicitly claim no acceptance. Missing, extra, reordered, or path-
mismatched commits fail validation.

One additive source-only alternative represents a synchronized carried commit
that was already published and accounted while blocked, then later accepted
without another source commit or push. That repository has an empty current
range and requires `old_revision == prepared_revision == final_revision`, plus
hash-bound prior accounting, its exact blocked/no-acceptance status evidence,
the formerly carried revision, and current acceptance evidence. The prior
accounting must itself validate and attribute that exact revision to the now
triggering unit as a carried commit. This alternative cannot be used for
planning transport and does not weaken planning-last suffix or readback checks.

Chronology remains bound to the exact timestamp strings in the prepared plan
and executed receipt. When an evidence timestamp carries only whole-second
precision (including a normalized all-zero fractional suffix), ordering treats
it as that represented one-second interval; a
higher-precision observation inside the same second is valid, while any value
at or beyond the next second fails closed.

Prepared-plan provenance has two additive forms. The standalone form binds a
`push_bundle_plan.v1` file directly. The container form binds an immutable
`work_unit_automation_receipt.v1` by path/hash with `member: push_plan`; the
validator requires executed `PreparePush`, transition `push-bundle-prepared`,
matching project/unit/bundle identities, and validates the embedded plan rather
than accepting a caller-reconstructed copy.

Prepared-event provenance likewise accepts the existing standalone event file
or a transition-ledger intent/completion pair. The paired form binds both files
by exact hash, transaction and event identities, completion-to-intent linkage,
committed status, the embedded prepared event, and its receipt link back to the
exact prepared-plan container.

Source repositories require `prepared_revision == final_revision`. Exactly one
external repository may have role `planning-transport`. Its prepared revision
may be an ancestor of final only when every suffix commit is classified as
workflow/publication finalization and every changed path is inside the
receipt's explicit transport allowlist. Final, live HEAD, upstream readback,
and executed receipt must agree; force push, dirty/divergent worktrees, or
non-monotonic chronology reject.

`RecordPublication` normally requires every live repository to equal that
published final revision. One narrow planning-only prerequisite state is also
accepted: the remote must still equal the executed final revision, while the
clean local planning branch may be ahead only by commits whose complete path
set is exactly the bound executed-push receipt and the accounting receipt being
consumed. Both paths must be present, every suffix commit must be nonempty, and
the suffix length must equal the observed ahead count. This does not admit a
source-repository suffix, dirty or divergent state, remote drift, unrelated
workflow files, or a general planning-ahead exception. The prerequisite suffix
is published only with the final planning closure after `RecordPublication`.

For an `intervening_accepted_publication` recovery only, the local prerequisite
suffix contains just the accounting receipt when the bound executed receipt's
exact path and hash still validate and exactly one enumerated intervening
planning-evidence blocker commit contains that path in the recovered Git
range. The suffix remains clean, ahead-only, nonempty, and accounting-only.
Missing or alternate history rejects. Accounting without this recovery proof
continues to require both accounting and executed-receipt paths.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action RecordPublication `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <repository-map> `
  -PublicationAccounting receipts/<accounting-receipt>.json
```

The command previews by default. With `-Execute`, it revalidates all document
and live evidence, clears only the exact matching pending bundle, and appends a
push event binding both accounting and executed-push evidence. It performs no
Git, device, validation, or acceptance mutation. A second consume fails because
the exact pending bundle no longer exists.

`ReconcilePublication` remains exclusively for a push that genuinely preceded
`PreparePush`; it rejects planned accounting and cannot manufacture a plan or
executed receipt.

## Published prerequisite suffix reconciliation

When the exact local prerequisite suffix described above was published by an
external no-force operation before `RecordPublication` consumed the pending
bundle, ordinary accounting must continue to reject the now-advanced planning
remote. Preserve that incident with the additive
`published_prerequisite_suffix_reconciliation.v1` contract and the distinct
`ReconcilePublishedPrerequisiteSuffix` action.

The reconciliation revalidates the unchanged planned accounting and both
bound receipt hashes. Its execution-time planning final is the exact parent of
the current planning revision. The current local HEAD and upstream readback
must equal that revision, the worktree must be clean, and the parent-exclusive
range must contain exactly one nonempty commit whose complete changed-path set
is exactly the bound executed-push receipt and planned-accounting receipt.
Every declared source repository remains clean and upstream-exact at its
executed revision. Branches, upstreams, unit, project, bundle, commit, tree,
path, hash, and chronology bindings remain exact.

The evidence must state that the publication was no-force and did not rewrite
history. Dirty, ahead, behind, divergent, nonancestor, alternate-history,
missing-object, missing-receipt, stale-hash, extra-commit, extra-path, source-
drift, wrong-unit, wrong-bundle, force, or rewrite observations reject. This
route is not remote-drift tolerance, unplanned-publication recovery, or the
planning-suffix rewrite incident route.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action ReconcilePublishedPrerequisiteSuffix `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <repository-map> `
  -PublishedPrerequisiteSuffixReconciliation receipts/<reconciliation>.json `
  -Execute
```

The command revalidates the document and live repositories, clears only the
exact matching pending bundle, and appends a distinct
`published-prerequisite-suffix-reconciled` publication event. It changes no
unit status, validation, acceptance, Git, device, tag, or release state. A
second invocation fails because the pending bundle was already consumed.

Use
[`templates/published-prerequisite-suffix-reconciliation.example.json`](../templates/published-prerequisite-suffix-reconciliation.example.json)
as the portable evidence shape after owner-lane composition. Run
`scripts/Test-PublishedPrerequisiteSuffixReconciliation.ps1 -SelfTest` for the
focused exact and damaged matrix, followed by the automation and workflow
contract suites.

## Planning-only suffix rewrite incident recovery

An already published planning-only finalization suffix that was subsequently
replaced with `--force-with-lease` does not satisfy ordinary
`RecordPublication`, and it is not an unplanned publication or intervening
accepted publication. Preserve that incident with the additive
`planning_suffix_rewrite_recovery.v1` contract and the distinct
`ReconcilePlanningSuffixRewrite` action.

The recovery binds the complete, still-valid planned-publication accounting,
so the original prepared plan/event and no-force source-first/planning-last
execution remain authoritative facts. It separately binds the planning
prepared commit/tree, the first published suffix commit/tree, the replacement
commit/tree, their common prepared parent, the exact two-path set changed by
both children relative to that parent, the exact one-path tree delta between
the children, current replacement remote readback, and the explicit force-with-lease fact. Every
declared source repository must remain clean and synchronized at its exact
executed revision. Both planning commits must still exist locally; missing
objects fail closed.

The route is deliberately two alternative one-commit children with exactly two
common parent-relative paths and exactly one replacement-delta path drawn from
that common set. It is not general force-push tolerance, remote-drift
tolerance, or a way to account for source rewrites.
Dirty, ahead, behind, divergent, alternate-path, unrelated-bundle, missing-
object, source-rewrite, or already-consumed state rejects. The action clears
only the matching pending bundle and appends a distinct push event. It does not
change unit status, validation, acceptance, Git, devices, tags, or releases.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action ReconcilePlanningSuffixRewrite `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <repository-map> `
  -PlanningSuffixRewriteRecovery receipts/<rewrite-recovery>.json `
  -Execute
```

Use [`templates/planning-suffix-rewrite-recovery.example.json`](../templates/planning-suffix-rewrite-recovery.example.json)
as the portable shape. Evidence authors replace every synthetic revision,
tree, path, and hash with observations from the exact incident.

The first implementation checkpoint modeled each suffix as changing one path.
A subsequent canonical tree audit showed that both suffix children changed the
executed-push and planned-accounting paths relative to the prepared parent,
while only planned accounting differed between their trees. No recovery had
been consumed; the follow-up retained the original checkpoint and corrected
the unconsumed contract plus its damaged fixtures.

If the external planning checkpoint was published early but every source
remote is still unchanged, preserve that ordering fault in a hash-bound
`publication_ordering_interruption.v1` receipt and pass it to a fresh
`PreparePush` call. The owner accepts only clean exact refs: the live planning
remote must equal the recorded early checkpoint and be an ancestor of the
local prepared checkpoint, while each live source remote must equal the
recorded unpublished revision and be an ancestor of the local source revision.
The new plan embeds the receipt binding and explicitly claims neither source
publication nor corrected planning-last chronology. This route performs no Git
mutation and is not `ReconcilePublication`.

Run `scripts/Test-PlannedPublicationAccounting.ps1 -SelfTest` for focused valid
and damaged document coverage, followed by the automation and workflow suites.

## Exact multi-accepted-unit prepared ranges

An immutable prepared/executed bundle may opt into `accepted_unit_attribution`
only when its exact range contains multiple separately accepted units. The
single prepared trigger remains `triggering-unit`; each additional accepted
unit uses `bundle-accepted-unit`, has accepted status evidence, and owns at
least one exact non-overlapping commit. Normal blocked carried-unit and later
intervening-unit rules remain unchanged. Gaps, overlap, duplicates, stale
range identity, blocked units, or trigger substitution reject.
