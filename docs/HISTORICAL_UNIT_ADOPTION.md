# Historical Iteration-Unit Adoption

## Decision

Current and future iteration units remain closed against the portable workflow
lifecycle, project validation profiles, and current resource-kind registry.
An immutable unit already in terminal `accepted` or `blocked` state may retain
legacy vocabulary only through a project-owned
`historical_unit_adoption_receipt.v1` referenced and hash-bound by compact
workspace state.

## Contract

Each receipt binds the project, source workflow release and commit, and every
adopted unit by ID, project-relative path, complete-file SHA-256, exact terminal
status, terminal event/evidence, and exact normalization mappings. Unknown
legacy categories and profiles map into current portable routing semantics;
their original domain meaning remains visible as a tag or limitation. Mappings
must cover exactly the unknown values—neither missing nor extra entries pass.

Resource kinds may use a `null` current target only for historical-only,
non-executable semantics. This preserves old observation evidence without
claiming a current isolation or lease contract. In particular, an old
`network-interface` noun does not become a current portable resource kind.

An immutable terminal unit may also retain a formerly valid instruction-impact
decision and instruction-surface actions. The receipt maps the exact legacy
impact to `update` and names every affected surface path whose historical
`review-no-change` action now requires `update`. These mappings must cover
exactly the current semantic mismatches; missing, extra, renamed, or action-
drifted surfaces reject. The unit and its historical instruction bytes remain
unchanged, and current or future units cannot use this route.

## Fail-Closed Boundary

Validation rejects receipt-reference hash drift, unit-byte drift, changed
status, missing or duplicate units, duplicate or invalid mappings, missing
terminal evidence, unknown normalized targets, incomplete instruction-impact
or surface-action coverage, and adoption by a current or future unit. Removing
the receipt restores strict current validation; it never creates an ambient
compatibility mode.

Historical unit files and event lines remain byte-unchanged. A project adds
only the receipt and compact-state reference. The receipt conveys workflow
validation semantics only; it cannot alter runtime, activation, repository
scope, device behavior, Git authority, or downstream lane authority.

## Validation

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-HistoricalUnitAdoption.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1 -WorkspaceRoot <project-root>\morphospace
```

The focused self-test covers one positive adoption and nine damaged cases.
