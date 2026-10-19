# Retiring active work before changing direction

Use `RetireActive` when an explicitly reviewed change of direction requires a
new objective or development envelope. It closes the current work without
accepting it and returns the project to idle. It preserves the old unit and
its existing evidence byte-for-byte.

`SupersedeActive` remains the direct replacement route within the old unit's
write scope. `AmendActiveWriteScope` remains a bounded correction within the
existing objective, project and agent envelope. Neither action authorizes a
different product architecture or new source authority.

## Supersession-origin retirement

An active replacement produced by `SupersedeActive` has no ordinary Claim or
admission of its own. Use `active_unit_retirement.v2` for that origin; do not
manufacture those events or put a supersession into the v1 `claim` field.
Ordinary admitted units keep the existing v1 request, receipt and history
semantics. The same `RetireActive` CLI dispatches the closed request schema;
there is no bypass flag or caller-supplied trusted-history token.

V2 replaces `claim` with `ownership.kind: supersession`. It binds the root's
actual ordinary admission and Claim, the current assessment bound by the real
proposed-to-active owner projection, the exact
effective repository map and each ordered supersession event, transaction,
intent, completion, retained request and owner result. The owner recomputes
these bindings from the real transactions and the current unit/source artifact.
The closed `ownership.repository_maps` array supplies one exact path/raw-hash
reference per distinct map hash bound by those producers, sorted by hash.
Historical maps are read only from those reviewed references and the known
preparation/current map bindings; unrelated paths grant no authority.
The required `ownership.validation_attempts` array retains every intervening
`ReturnToActive` validation receipt in actual event order as
`{event_id,path,raw_sha256,canonical_sha256}`; it is empty when none occurred.
These are exact reviewed hashes of the retained bytes now. The old action did
not pin receipt bytes or require a Git addition, so this binding does not claim
an original-time raw hash or original committed custody. Receipt semantics and
artifact hashes still require authentication. Current, interrupted and historical
retirement verification recomputes the whole ownership binding, rejecting later
changes, omissions or reordered attempts. Ordinary v1 retention is unchanged.
The owner checks the original preparation/admission and every intervening supported
owner continuation, rejects ambiguous, forked, replayed or resurrected chains,
and authenticates the same origin on interrupted execution and later readback.
Retained lifecycle replay uses the authenticated project and feature lock at
each step to derive the producer's module registry. Historical repository heads
and dirty-repository observations remain inert, schema-checked observations of
declared repositories; every other state field still requires exact equality.
The schema example is
[`active-unit-retirement-v2.example.json`](../templates/active-unit-retirement-v2.example.json);
its zero hashes are placeholders and supply no authority.

Both versions require exact current preimages, an unchanged accepted checkpoint,
no conflicting queue/blocker/publication/validation selector, and the intended
replacement identity to remain absent. Writable source checkpoints must be
clean descendants of their locked baseline; readonly dependencies remain exact.
Only an authenticated owner planning projection may account for lifecycle dirt
or its clean linear checkpoint. V2 does not accept arbitrary dirty overlays.
Preserve owned implementation in a reviewed clean checkpoint before retirement;
the checkpoint is retained source, not accepted product evidence.

V2 emits `active_unit_retirement_receipt.v2`, retaining the exact `ownership`
binding with `accepted: false` and `source_mutation_performed: false`. The writer
still changes only the current-unit pointer and event tail, preserving the old
unit, failed validation checkpoint, acceptance and source evidence. Historical
verification follows that origin after idle preparation and a later admission
or accepted boundary. V2 also checks the retirement completion's canonical JSON
and single-LF producer framing. This is not an independent original completion
hash or attestation of its otherwise valid `completed_at` value.
No workflow retirement receipt proves runtime cleanup,
child EOF, app-data release, device readiness or permission to replace a live
source process. Those effects remain with their actual owners.

V2 may retain the existing optional `retained_claim_diagnostic`,
`retained_ready_diagnostic` and `retained_lifecycle_diagnostics` bindings for
the **root ordinary unit**. Their closed producer schemas, raw/canonical hashes,
original introduced commit/blob, exact transaction and original tooling-context
joins remain mandatory. The verifier selects `ownership.root_unit_id` and its
actual `root_claim`; it never invents a Claim or diagnostic for the supersession
replacement. These files must remain inert, outside original ledger artifacts,
and contribute only their authenticated final-byte planning projection. The
retained request artifact binds the complete optional fields. They grant no
current gate, prerequisite, validation, acceptance or publication credit.

## Review and retire

1. Preserve implementation checkpoints and distinguish them from accepted
   product evidence. Record the reason for retiring the work and a distinct
   intended replacement identity.
2. Observe the complete current source composition and every repository the
   old unit may write. Bind clean commits and trees. Checkpoint owned changes
   and resolve unowned dirt before retirement; the action does not delete,
   merge, discard or transfer source.
3. Prepare the exact owner request against the current project, feature lock,
   compact state, event ledger, repository map and unit. Review the dry run
   and execute only its exact SHA-bound request.
4. Verify the committed owner transaction and retirement receipt. The old
   unit remains immutable evidence. The authenticated current-work view
   classifies it as retired active work, not an accepted prerequisite.

The reviewed input may live in ignored local storage outside the workspace.
Execution preserves its exact bytes at
`receipts/<retirement_id>-request.json`, alongside the distinct retirement
receipt. This avoids requiring a planning request to bind the Git commit that
contains itself. Initially observed source repositories must be clean and
backed by distinct Git repositories. Writable entries must map to their exact
Git roots and retain their locked baseline as an ancestor. A read-only source
dependency may map to an authenticated nested directory, as permitted by the
preparation-owned repository map and source lock; retirement observes the
complete backing Git repository and requires its exact locked commit, tree,
role, and clean worktree. Nested writable or planning entries, duplicate
backing repositories, path traversal, and reparse-backed aliases are rejected.
The lock's `materialization_path` remains the producer's materialization label;
retirement does not reinterpret it as a Git-relative path.

A project-shell read-only planning repository may instead retain the exact
owner-produced lifecycle projection when it strictly contains the active
workspace. The original preparation lock may still be HEAD with unstaged
lifecycle dirt, or a clean current HEAD may be a linear descendant of that
lock whose commits change only authenticated projection paths. This exception
accepts only the final-byte projection of an authenticated
`Prepare`/`Admit`/`Ready`/`Claim` chain, or its exact
`Prepare`/`Admit`/`RetireProposed`/`Admit`/`Ready`/`Claim` replacement form,
followed by zero or more contiguous same-unit `AmendActiveWriteScope` and
`UpgradeToolingContext` transactions. Every continuation is revalidated by its
owning historical semantic verifier. A frozen unit may also retain its exact
instruction completion, FreezeCandidate, BeginValidation, fail RecordValidation,
Resume and passing scope-disposition ResolveBlocker chain. Retirement
authenticates each preceding target and reconstructs the exact next state and
unit; Resume and resolution preserve the nonpass checkpoint and acceptance.
The fail receipt must retain its original committed blob across every later
path-changing commit, including a rewrite followed by restoration. Its hashed
artifacts and resolution evidence remain exact. Other lifecycle transitions,
validation promotion, and unknown projection changes are rejected. An upgrade also binds the exact
compatibility, publication, protocol, and affected-validation proof files
referenced by its authenticated request and resulting tooling context.
The verifier applies last-writer wins in ledger order and rejects staged
changes, deletes, renames, conflicts, outside-workspace paths, pending
artifacts, incomplete transactions, and target, artifact, intent, or completion
drift. For a committed descendant it also checks every changed path in every
intervening commit and the live bytes against the authenticated projection;
unrelated paths remain forbidden even if a later commit reverts them. This
grants no general planning drift or arbitrary descendant-HEAD allowance.

```powershell
pwsh -NoProfile -File <work-environment>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action RetireActive -WorkspaceRoot <workspace> -UnitId <old-unit> `
  -RepoMapPath <repository-map> -ActiveUnitRetirement <reviewed-request.json> `
  -ExpectedActiveUnitRetirementSha256 <request-sha256> `
  -OutPath <workspace>/receipts/<retirement-id>.json -Execute
```

Conflicting queued work, validation selection, publication or incomplete
transactions must be resolved through their owners first. A retirement is not
a way to hide damaged current history or a failed transaction. Exact retries
authenticate the original transaction; they do not append another retirement
or overwrite retained evidence.

An old, never-admitted proposal is excluded only when the ordinary preparation
classifier proves it inert against the authenticated owner control surface.
It remains byte-exact; a queued, admitted, referenced or in-flight proposal
receives no exemption. The named replacement must still be absent.

## Prepare the replacement

Once the project is idle, checkpoint the completed planning retirement so the
next preparation observes a clean current planning source. Then use ordinary
`PrepareDevelopmentEnvelope` to review
the revised repository roots, feature closure, permissions, build and device
ceilings. Bind fresh clean source identities. Then use `AdmitDevelopmentUnit`,
`Ready`, `Inspect` and `Claim` for the named replacement.

The new unit must state which earlier implementation checkpoints it retains
and which outcomes remain unverified. Retirement does not create the new unit,
grant source or device work, validate a candidate, accept either unit or
publish anything. Do not manufacture an accepted or blocked result merely to
reach an idle state. Do not create a placeholder successor to bypass the
supersession scope check.

## Validation

Use the focused retirement and continuation checks. Positive fixtures must be
produced by the actual owner actions. Cover dry-run nonmutation, exact replay,
interruption recovery, source/overlay drift, conflicting current authority,
damaged transaction evidence and preservation of old bytes. Continue through
fresh preparation, admission and ordinary claim; reject attempts to resurrect
the old unit or use it as accepted evidence.

The affected-validation registry partitions the focused retirement owner into
bounded scenario leaves. The core leaf depends on every nested-source,
amendment, recovery and damage leaf before it provides the retirement contract;
one scenario cannot stand in for the complete focused result. Direct manual use
of `Test-ActiveUnitRetirement.ps1 -SelfTest` still runs every scenario.

Historical auditing remains separate. Later continuation must authenticate
retirement after subsequent owner events without retrofitting new instruction
requirements onto the retired unit.

## Optional inert Claim diagnostic retention

A reviewed retirement request may bind one `retained_claim_diagnostic` when an
older executed `Claim` returned an automation receipt that was committed beside
the transaction, but the original intent artifacts and event receipts are empty.
The binding uses the closed `inert-claim-diagnostic` role, the v1 automation
producer schema, a `receipts/<name>-claim-<YYYYMMDD>.json` path, exact raw and
canonical hashes, the original committed addition and full Git blob SHA1/SHA256, and the original
Claim target unit's tooling context (null only when the original Claim had none).
A later context upgrade is not a substitute. Checkout normalization does not
replace either raw binding: the full committed blob must also match the complete
worktree diagnostic canonically.

Retirement verifies the whole closed producer receipt, its ready-to-active
transition, identities and timestamp, the committed Claim and context, and the
validation matrix and graph scope derived from the retained Claim unit. Historical
preflight observations remain unused diagnostic data; they are not recreated or
used as present authority. Arbitrary evidence/control paths, producer roles,
non-Claim authority payloads and changed bytes are rejected. The same binding is
verified on transaction recovery and historical retirement readback.

This option retains bytes only. It never inserts artifacts or receipt references
into the original Claim ledger, nor supplies validation, gate, prerequisite,
acceptance or publication credit. Requests without the optional binding retain
the existing behavior.

## Optional inert Ready diagnostic retention

A request may additionally bind one `retained_ready_diagnostic` under the closed
`inert-ready-diagnostic` role and `receipts/<name>-ready-YYYYMMDD.json` namespace.
It uses the same raw, canonical, committed blob and original tooling-context pins
as Claim retention, with its own `introduced_commit`, `event_id`, `transaction_id`,
`intent_sha256` and `completion_sha256`. The Ready introduction need not be the
Claim introduction.

The owner authenticates the original executed v1 Ready output, its committed
transaction and ledger event, the exact proposed-to-ready transition with no
current unit and the target ready queue, and its immediate original Claim
preimage. It verifies original declaration-shaped matrix and scope fields and
both introduced and current Git blob bytes. Original intent artifacts and event
receipts must be empty. Historical observations remain inert; retention adds no
ledger artifact, validation, gate, acceptance or publication credit. Missing or
tampered bindings leave the committed descendant unauthenticated.

Ready may refresh its recorded repository heads. The owner verifies the exact
original predecessor transaction and preimage, retaining those historical heads
as inert observations without replaying current repository observations.

The optional `retained_lifecycle_diagnostics` request field retains up to three
original BeginValidation, failed RecordValidation and Resume wrapper outputs.
Each is bound to its original Git addition and exact raw/canonical bytes, blob,
owner event, timestamp, action, status and current-owner projections. The reader
authenticates these as inert diagnostics; they do not replace transition
artifacts, supply acceptance or grant a runtime effect. Original Ready/Claim
diagnostic filenames may use either the date suffix or the producer's undated
`-ready.json` / `-claim.json` spelling, with the same semantic and blob guards.
