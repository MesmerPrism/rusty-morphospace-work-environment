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

## Planning Targets And Workflow Evolution

The portable manifest retains three feature units between workflow changes and
70 percent feature effort as advisory planning defaults. They are not admission
prerequisites, an embargo, or a historical counter that agents must reconstruct.
The existing field names remain compatible; their values may be adjusted as
planning preferences without changing accepted units or their evidence.
Validation that directly proves product behavior counts toward that product's
effort. Use observed costs and blocked work to assess the balance rather than
create an effort-accounting ledger.

Defer cosmetic workflow changes when they would interrupt useful product work.
When an obsolete rule blocks authorized work, causes repeated failures, or
requires disproportionate validation, describe the concrete failure and the
smallest owner repair. State what invariant the rule protects, which current
consumers the repair affects, and which checks prove the replacement. Continue
independent product work on the adopted owner while the repair is reviewed.

Use the existing owner route for changes to workflow, validation, publication,
or privacy authority. Its exact candidate approval remains required where that
boundary applies; the planning targets add no separate exception request or
second approval. Ordinary instructions and design preferences should guide
agent judgment. Hard gates should protect actual authority, unsafe effects,
concurrent writes, current transaction integrity and required evidence.

After a failure, use a bounded diagnostic attempt that adds information; repeat
only when new evidence or a changed input makes the attempt useful. Preserve a
compact failure and the next actionable step. Do not create a successor merely
to improve wording, or make a retired unit acquire a new feature prerequisite.
Evaluate current continuation separately from a requested historical audit.

## CI Execution Budget

Run candidate validation from pull-request events, not from both a feature
branch push and its pull request. Retain `main` push validation as post-merge
readback and keep manual dispatch for deliberate Deep runs. Group candidate
runs by pull request so a newer revision cancels its superseded run; never
cancel a `main` readback run merely because another merge arrives.
Use `!cancelled()` on the 21 job or step guards that must remain eligible after
an ordinary prerequisite or step failure. It preserves their required binding,
diagnostic, evidence, and cache paths but becomes false on cancellation so the
segmented graph can stop. Main segment and delta job conditions retain implicit
`success()` semantics and remain failure-sensitive. Request ordinary
cancellation first; force-cancel only a legacy or already-started run that
remains alive, accepting that its terminal
evidence may be incomplete and cannot count as a pass.

Keep Linux Quick, Windows Quick, and Windows Standard as separate required
contexts. Quick owns the common portable suite. Standard runs only the
additional Work Unit Automation delta and relies on the required Quick
contexts; it must not replay the complete Quick tier. Use the same split
locally: run Quick once, then invoke
`Test-WorkflowContracts.ps1 -StandardDeltaOnly` only when the
Standard delta is warranted. Preserve cumulative `Test-WorkEnvironment.ps1
-Tier Standard` only as a compatibility aggregate for callers that have not
already run Quick. Pin third-party actions to reviewed full commits and update
those pins through the locked validation-authority path.

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
path/mode/size/hash set, require a repository-owner authorization decision
after that evidence is visible, and emit a typed authorization that is
idempotent only for the exact candidate evidence within freshness and unusable
for another candidate. The owner may make that decision directly or explicitly
delegate it to the active agent through
[Full Authority Mode](FULL_AUTHORITY_MODE.md); the delegated agent still
reviews and signs each fresh exact request. The authorization is consumed and
inert after its head becomes an ancestor of trusted base.

That owner authorization is an external trust root. Full Authority Mode is an
operational delegation that removes repeated chat prompts; it is not the
static admission itself. Never replace the exact candidate-bound signature
with a standing bypass actor, a wildcard approval, candidate code, or a
temporary removal of branch protection. Static admission, dynamic validation,
acceptance, and publication remain separate facts even when one delegated
agent is authorized to decide and perform each step.

For the exact protected-without-base-approval result, emit the canonical typed
owner request before failing when no authorization comment exists. The request
must expose the complete ordinal-sorted candidate artifact evidence and the
immutable assessment hash. The owner signs only a payload derived from that
request; comment fields never supply expected repository, Git, artifact, or
assessment evidence. A stale authorization remains inert history and triggers
a fresh request instead of blocking recovery. Keep signing outside the
read-only workflow. Its base-owned comment reader uses an ephemeral token with
only `issues: read` to avoid the runner IP's shared anonymous quota; the token
is removed from the environment before subprocesses and never reaches
candidate code. Bounded retries cannot replace waiting for an exhausted quota,
and transport authentication cannot replace the exact owner signature. See
[External Validation Authority](EXTERNAL_VALIDATION_AUTHORITY.md) for the
deadline, diagnostics, and adoption proof.
