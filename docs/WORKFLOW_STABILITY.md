# Workflow Stability And Feature Throughput

This policy keeps safety evidence proportional to product work. It does not
weaken validation, publication, device, or repository authority boundaries.

## Golden Path

Use one unit captain from `proposed` through acceptance. Split a unit only when
write authority, publication authority, or rollback authority changes. Host
build, browser validation, device validation, and evidence capture are stages
of the same feature unit when they share those authorities.

Before Claim, run `Inspect` with the exact repository map and device serials
that Claim will receive. The returned `claim_preflight` must report
`ready_to_claim: true`. It binds:

- every writable repository and its current commit/tree when Git-backed;
- every read-only dependency repository and declared input path;
- every instruction alias, path, and stable file observation;
- declared disk floor, required tool availability, and exact product inputs;
- resource identities, validation tier/matrix, and required device selection.

Claim repeats the same checks and fails before changing state when any item is
unresolved. Do not claim first and repair repository maps, dependency closure,
or instruction paths later.

Generate a handoff without paraphrasing commands:

```powershell
pwsh -NoProfile -File .\scripts\New-WorkUnitHandoff.ps1 `
  -WorkspaceRoot <project>/morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map.json> `
  -Timestamp <utc-timestamp> `
  -OutPath <project>/morphospace/receipts/<unit>-handoff.json `
  -Execute
```

The generated handoff copies validation and acceptance command strings exactly
from the unit and binds them to unit, state, event-ledger, repository commit,
and repository tree hashes. It does not run those commands or grant authority.

## Validation-Only Units

Set `work_mode: validation-only` only for a unit whose product/source behavior
will not change. Such a unit:

- declares only the `validation` change category;
- uses `instruction_impact: review`;
- records every required instruction surface as `review-no-change`;
- may run host or serial-scoped device validation, but makes no production edits.
- restricts writable paths to project `morphospace/` state and evidence; product
  repositories and artifacts are read-only dependencies/product inputs.

If validation discovers a product defect, terminalize the validation-only unit
truthfully and propose a feature unit. Do not expand the validation-only unit
into implementation or device work.

## Stability Window

After a workflow-contract change is adopted, complete three feature units
before proposing another workflow-contract change. Validation-only units do not
advance or reset that counter. A security or data-loss correction may interrupt
the window only with explicit owner approval and a narrowly documented reason.

Across a rolling feature cycle, target at least 70 percent of work-unit effort
on product behavior and content. Validation time counts as feature effort when
it directly proves the current feature unit; reusable workflow/schema repair
does not.

During the stability window:

- record workflow annoyances as backlog evidence rather than repairing them in
  the active feature unit;
- stop after one bounded retry when the same stage fails without new evidence;
- do not create a successor merely to improve protocol wording, receipts, or
  instruction metadata;
- preserve a genuine product blocker as product evidence, not workflow debt.

## Semantic Checks

Static gates must validate meaning at the cheapest trustworthy layer. Prefer,
in order: parser/AST or manifest semantics, compiled symbol/type checks, then a
bounded behavioral test. A literal source-token search may be authoritative
only when the file format defines that literal token as the contract.

When formatting, aliases, equivalent expressions, or code generation can
preserve behavior while changing text, a raw token search is diagnostic only.
It may not block acceptance or trigger a corrective unit by itself.

## Trust-Root Evolution

An in-repository policy cannot permanently authorize changes to itself without
creating a circular trust claim. Before the last exact approval is consumed,
maintain a separate owner-controlled policy-evolution gate. The gate must run
base-owned code, bind the exact base/head commit and tree plus the complete
path/mode/size/hash set, require a human owner decision after that evidence is
visible, and emit a typed authorization that is idempotent only for the exact
candidate evidence within freshness and unusable for another candidate. It is
consumed and inert after its head becomes an ancestor of trusted base.

That owner authorization is an external trust root. It is not static
admission, dynamic validation, acceptance, or publication authority. Never
replace it with a standing bypass actor, a wildcard approval, candidate code,
or a temporary removal of branch protection.

For the exact protected-without-base-approval result, emit the canonical typed
owner request before failing when no authorization comment exists. The request
must expose the complete ordinal-sorted candidate artifact evidence and the
immutable assessment hash. The owner signs only a payload derived from that
request; comment fields never supply expected repository, Git, artifact, or
assessment evidence. A stale authorization remains inert history and triggers
a fresh request instead of blocking recovery. Keep signing outside the
anonymous read-only workflow.
