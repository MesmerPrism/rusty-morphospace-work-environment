# Executed Prepared-Publication Reconciliation

Use this route only when an already executed, no-force `PreparePush` bundle has
immutable evidence that ordinary `planned_publication_accounting.v1` must
reject. The supported shape is deliberately narrow:

- the recorded plan timestamp is later than the immutable executed-push start;
- an exact source final is a normal merge integration whose ordinary
  `diff-tree --no-commit-id --name-only -r <merge>` projection is empty or does
  not describe the unit delta;
- every repository still has exact no-force remote readback;
- the accepted unit and matching pending bundle are unchanged; and
- the planning checkout contains only the bound executed receipt and the new
  reconciliation input as untracked pre-transition evidence.

This is classification, not correction. Keep the original plan, transition
intent/completion, timestamps, executed receipt, commits, trees, parent order,
and refs byte-for-byte. State explicitly that ordinary accounting is not
satisfied, no retrospective plan or corrected chronology is claimed, and merge
history was not flattened.

## Evidence shape

Author `executed_prepared_publication_reconciliation.v1` from
[`templates/executed-prepared-publication-reconciliation.example.json`](../templates/executed-prepared-publication-reconciliation.example.json).
Bind:

1. the exact `push_plan` member inside its hash-bound PreparePush receipt;
2. the exact preparation transition intent and committed completion;
3. the exact executed-push receipt;
4. the original preparation, execution-start, and execution-finish timestamps;
5. every planned/executed repository identity, old/planned/final commit, final
   tree, branch, upstream, and current remote readback;
6. a sorted ordinal path-set count and SHA-256 for every complete
   old-exclusive/final-inclusive history; and
7. for `merge-integration`, the merge base, both parent commits and trees in
   parent order, and four exact path projections: base-to-side,
   base-to-protected, protected-to-final, and side-to-final.

Path-set SHA-256 is computed over unique repository-relative paths sorted by
ordinal comparison, each encoded as UTF-8 without BOM and separated by LF,
including one final LF. The union comes from every commit in
`git rev-list --reverse <old>..<final>`; linear commits must be nonempty and
single-parent. Merge integration is limited to the exact side-parent commit
followed by its merge final; it additionally requires the side delta to equal
the final delta against the protected parent.

## Transition

After focused validation and exact live readback, run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action ReconcileExecutedPreparedPublication `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <accepted-unit-id> `
  -RepoMapPath <repository-map> `
  -ExecutedPreparedPublicationReconciliation receipts/<reconciliation>.json `
  -Execute
```

The action revalidates all evidence and live refs, consumes only the exact
matching pending bundle, and appends an
`executed-prepared-publication-reconciled` event. It performs no Git, source,
validation, acceptance, device, release, or history mutation. Reuse fails once
the pending bundle is gone.

## Rejection and routing

Reject dirty source worktrees, extra planning paths, missing or reordered
repositories, stale refs, abbreviated commits, ancestry gaps, unbound merges,
path-set drift, force pushes, rewritten timestamps, a corrected-chronology
claim, a retrospective plan claim, or an ordinary-accounting claim. Continue
to use `RecordPublication` for evidence that satisfies normal chronology and
commit enumeration. Use unplanned-publication, retirement, prerequisite-suffix,
or planning-rewrite recovery only for their separately documented shapes.

Before proposing another reusable recovery for a dirty authoritative checkout,
run a read-only preflight against that real consumer. A single awkward checkout
is not permission to generalize the workflow; stop after one bounded recovery
unless a second consumer, neutral conformance harness, or explicit owner
decision justifies a shared surface.

Validate with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExecutedPreparedPublicationReconciliation.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1 -StandardDeltaOnly
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1
```
