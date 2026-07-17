# Planned Publication Accounting

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

Run `scripts/Test-PlannedPublicationAccounting.ps1 -SelfTest` for focused valid
and damaged document coverage, followed by the automation and workflow suites.
