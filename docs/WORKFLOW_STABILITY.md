# Workflow Stability And Feature Throughput

This policy keeps safety evidence proportional to product work. It does not
weaken validation, publication, device, or repository authority boundaries.

## Select The Guard Deliberately

Choose guard authority separately from validation depth:

- `fast`: bounded implementation, validation, or documentation across the
  unit's declared repositories and host/device stages; no release or change to
  product/workflow authority.
- `labs`: composition, activation, product authority, device policy, or
  repository routing.
- `locked`: releases plus public/private, workflow automation, state-machine,
  validation-routing, and recovery changes.

New units state `guard_profile` explicitly. Older immutable units may be read
through risk-tier inference for compatibility, but that inference is not the
authoring rule. Use `risk_tier` only to select how much evidence the current
change needs. For example, a `fast` product correction can use `deep`
validation without acquiring release authority.

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
- guard-profile sufficiency for the unit's authority category and publication
  boundary.
- an optional exact execution observation for package/application identity,
  signer fingerprint, grant mode, required CLI/NDK capability, and bridge/port
  readiness.

Claim repeats the same checks and fails before changing state when any item is
unresolved. Do not claim first and repair repository maps, dependency closure,
or instruction paths later.

If bounded feature implementation later discovers another writable path or
project-declared repository under the same authority and rollback envelope,
use `AmendActiveWriteScope` instead of releasing the captain or inventing a
successor unit. The amendment must be additive, remain inside project scope,
bind exact current state and the unchanged project spec, and retain the unit's
status. It does not authorize project-scope changes or execute product work.

When an exact validation attempt fails but the correction remains inside the
same feature unit and authority envelope, use `ReturnToActive` with that
non-passing receipt. The captain remains owner and the attempt remains in the
ledger. Use blocker recording plus `Resume` only when work actually stops or
authority is released.

Prefer this small observation over discovering immutable input mismatches after
an expensive build. The producer remains owned by the product/tool lane; Claim
only verifies its bound bytes and declared assertions and never treats the
observation as product validation.

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

## CI Execution Budget

Run candidate validation from pull-request events, not from both a feature
branch push and its pull request. Retain `main` push validation as post-merge
readback and keep manual dispatch for deliberate Deep runs. Cancel superseded
runs only when they address the same exact candidate head.

Keep Linux Quick, Windows Quick, and Windows Standard as separate required
contexts. Quick owns the common portable suite. Standard runs only the
additional `Test-WorkUnitAutomation.ps1` delta and relies on the required Quick
contexts; it must not replay the complete Quick tier. Pin third-party actions
to reviewed full commits and update those pins through the locked validation-
authority path.

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
