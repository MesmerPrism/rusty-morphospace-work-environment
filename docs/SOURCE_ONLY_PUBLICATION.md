# Source-only publication

## Independent source delivery while product adoption is pending

The stateless `New-SourceOnlyPublicationInput.ps1` actions `Disposition`,
`ObserveLanding` and `VerifyLanding` are separate from the accepted-trigger
publication transaction below. They never create acceptance, change a unit or
ledger, or weaken `PrepareSourceOnlyPublication`/`RecordSourceOnlyPublication`.

Use the closed `source-delivery-disposition-v1.schema.json` request forms:

1. `-Action Disposition -RequestPath <request> -ExpectedRequestSha256 <raw-hash>
   -WorkspaceRoot <frozen-consumer> -RepoMapPath <publication-map>
   -HumanDecisionPath <decision> -ExpectedHumanDecisionSha256 <raw-hash>
   -OutPath <new-disposition>`. The invoking authority must possess the explicit
   human decision; a JSON assertion supplies no delegation. The request pins the
   exact committed immediate Freeze/Begin consumer preimage and original map,
   the selected old dependency values by JSON pointer/hash, and a separate
   publication subject/map and FAST source package. Its only supersession is
   source-before-adoption ordering. The output says adoption pending, source
   not landed and no acceptance credit.
2. Qualify the committed publication subject with its own source checks and
   review, required protected CI and ordinary merge. Retain real successful
   terminal originals. Bracket the declared source checks with the fixed Git
   query `git --no-optional-locks --no-pager --no-replace-objects -C <source>
   status --porcelain=v2 --branch --untracked-files=all`; both observations must
   name the exact subject and contain no dirty/untracked status records. Retain
   their capture completion references and each check's exact argv/cwd.
3. The landing request binds those originals, source review, pinned provider
   executable and the normal merge command `gh pr merge <n> --repo <owner/repo>
   --merge --match-head-commit <subject>`. After the actual merge, capture
   `gh pr checks <n> --repo <owner/repo> --required --json name,state,link`, then
   `gh api --method GET repos/<owner/repo>/pulls/<n>`. Use
   `-Action ObserveLanding -RequestPath <request> -ExpectedRequestSha256 <hash>
   -RepoMapPath <publication-map> -OutPath <new-landing>` with the clean subject
   checkout retained. The source objects must prove the ordinary two-parent
   merge and exact subject tree; fresh remote readback must retain that merge.
4. `-Action VerifyLanding -LandingPath <landing> -ExpectedLandingSha256 <hash>
   -WorkspaceRoot <consumer> -UnitId <unit> -RepoMapPath <consumer-map>`
   authenticates the retained source evidence without another remote delta or
   publication. A validation artifact of kind `source-delivery-landing` invokes
   the same owning reader in the compatible owner. This authenticates only the
   stated source delivery and relationship, not fulfillment of an old product
   predicate, content equivalence, product validation or adoption. Every other
   criterion, command, gate and live owner guard remains mandatory.


The explicit `consumer.boundary_kind` selects separate authority proofs.
`frozen-consumer` preserves the original immediate Freeze/Begin, source and map,
and requires the independently authorized FAST publication package above.
`accepted-source-owner` instead binds the genuine committed Accept transaction,
passing receipt, accepted source revision and qualified interval/write scope.
An existing candidate Freeze also retains its raw receipt and original consumer
map binding; initial accepted owners acquire no invented Freeze prerequisite. It requires
`same-source`, a null `source_package`, and supersedes only the planning-layout
publication ordering through an explicit human decision. It does not relabel a
locked owner as FAST or require a fictional planning-role map. Both variants
start with zero landed and acceptance credit; neither changes the owner.
For an accepted owner the receipt's qualification base remains exact even when
the publication base is older. Qualified trigger paths remain within the unit;
carried publication paths must remain within project source scope. The complete
publication interval needs its own source checks/review and required CI proof;
accepted results do not automatically qualify carried source.

### Reviewed integration of an immutable accepted source owner

`accepted-source-owner-reviewed-integration` is a separate closed branch with
`relationship.kind=reviewed-integration` and a null `source_package`. It preserves
the original accepted source reference and receipt; it does not reinterpret
`same-source` or `reviewed-port`, extend an old unit's write scope, or transfer
acceptance or validation to the new candidate.

The accepted receipt supplies the original qualification base L, accepted head S
and complete changed paths D within the original unit scope. The separate
publication subject has base P, an independently authenticated already-published
normal merge, and candidate C. C must have exactly the ordered parents S and P.
Its tree must equal a conflict-free controlled native computation over those
parents and their unique real merge base M. No caller supplies an expected merge
tree, strategy, driver, resolution or arbitrary Git arguments. Original accepted
changes and the publication delta remain bounded by D; published changes retain
their own source/required-check/normal-merge evidence.

First author an `integration-computation-request` in the existing schema. Bind
the accepted consumer, original `source_reference`, new `publication_subject`,
separate `publication_map` and the retained `published_landing` for P. Retain a
genuine complete original of this exact invocation, using absolute host, script
and input/output paths:

```text
<pwsh> -NoProfile -File <New-SourceOnlyPublicationInput.ps1>
  -Action ComputeReviewedIntegration -WorkspaceRoot <accepted-owner>
  -RepoMapPath <publication-map> -RequestPath <request>
  -ExpectedRequestSha256 <raw-hash> -OutPath <new-computation.json>
```

The action emits the exact create-new computation path and raw hash. Set the
disposition request's `integration` to its `published_landing`, `computation` and
`computation_original` references. A successful process alone, or a substituted
and rehashed document absent from its actual stdout, is insufficient.

The producer uses a fresh private bare object database with read-only access to
already-present source objects. It clears the native child environment, retains
the fixed executable/configuration/arguments/stdin/raw terminal streams and
operation intervals, and performs no checkout, source object/ref/index write,
clone or network request. Storage must be outside the source and Git roots.
It removes the obsolete private database after retaining the proof files.
The source observation uses the existing safe content-observation contract and
requires an attached, clean source. Ambient `GIT_ATTR_SOURCE` refuses before
source observation. Tracked attribute inventory/modes/blobs must be identical
at M, S and P; all effective merge attributes must be unspecified. This minimum
refuses custom/union drivers, changed attributes, deletion/rename, mode change,
add/add, multiple bases and unsupported paths/types. A conflict's tree prefix
or empty stderr never substitutes for exit zero and exactly one tree OID.

Disposition remains zero-credit, read-only owner verification plus create-new
evidence. C still needs its own source checks, review, exact protected static
authorization, required CI and ordinary P/C publication. ObserveLanding retains
those new originals. VerifyLanding reauthenticates the immutable acceptance
prefix, original outer output and operation-specific native proof without a
new merge computation, private database or network request; ordinary immutable
Git object observations remain required. It permits a legitimate later owner
tail without rewriting the original acceptance or demanding republication.

A landing request retains the exact original provider and Git executable bytes
in `provider` and `source_git`, with their original invocation locations in
`provider_invocation_path` and `source_git_invocation_path`. ObserveLanding joins
those bytes to the selected live executables and captured argv. Later retained
verification authenticates the held bytes and original joins without requiring
the former executable to remain installed at that location.

Capture references use retained `task.root.command_capture_completion.v2`
originals with complete raw streams, EOF, actual exit/reap and no retry or
termination. The reader authenticates their byte/intent/argv joins; capture
records are executor evidence, not cryptographic proof of arbitrary execution.
Machine locators and human decision material belong in ignored evidence, never
committed source. Preserve the referenced files and source objects until their
consumers no longer need them. Preparing or verifying a record performs no
push, merge, signing, build, device or product-owner action.

Use `PrepareSourceOnlyPublication` and `RecordSourceOnlyPublication` when an
accepted `integration-batch` development integration or snapshot must publish
its source repositories but the distinct planning owner intentionally has no
remote. This is an ordinary two-phase publication mode, not recovery.

## Prepare inputs through the owner interface

Use `scripts/New-SourceOnlyPublicationInput.ps1` instead of writing a
project-specific plan generator. Its actions observe Git and produce create-new
inputs; the existing automation actions retain lifecycle authority.

1. Run `-Action Readiness -WorkspaceRoot <workspace> -UnitId <unit>
   -RepoMapPath <map> -PublicationId <id> -OutPath <readiness.json>` before
   committing to this publication route. Keep that publication ID through a
   bounded network retry or interrupted preparation/recording.
2. Produce the validation receipt with `scripts/New-ValidationReceipt.ps1`,
   supplying the actual validation outcomes in `-EvidencePath`. The builder
   observes repository revisions, scoped changed paths and artifact hashes;
   it does not run tests or infer successful outcomes. Evidence contains
   `receipt_id`, `tier`, `result`, `artifacts`, `criteria`, `gates` and
   `device_validation`. Each input artifact supplies only `artifact_id`,
   `kind` and `path`; relative paths resolve from the output receipt directory.

   An active-envelope source lock uses its authenticated effective-envelope
   lineage and original repository baselines. The producer requires that new
   branch's actual current validating unit, exact physical map and raw owner,
   source, Freeze and event bindings. Changes before and after extension remain
   in the receipt; the extension's effective head is never substituted for its
   original baseline. Ordinary source-lock receipt behavior is unchanged.
   Record and accept through the normal owner actions.
   The stateless builder accepts authenticated development-envelope source
   compositions through v3, including its separate tooling protocol. A later
   qualified constructor can produce the same validation receipt v1 for a
   frozen unit; RecordValidation and Accept still use that unit's bound owner
   executor and all current lifecycle guards. Construction does not upgrade
   the unit's tooling context.
3. Commit the accepted local planning checkpoint, rerun readiness, then use
   `-Action Plan` with the same workspace, unit, map and publication ID.
   Pass its output and SHA-256 to `PrepareSourceOnlyPublication`.
4. For each source in the plan's dependency order, use `-Action StartOperation`
   with the prepared `-PlanPath` and `-RepoId`. Perform the already-authorized
   external Git/provider operation, retain its actual outcome evidence, fetch
   the final target without moving the candidate HEAD, then use
   `-Action ObserveOperation`. Remote observation alone cannot establish that
   a particular command ran or that no force option was used.
5. Use `-Action Execution -PlanPath <prepared-plan>
   -OperationObservationPaths <ordered-observations> -RepoMapPath <map>
   -OutPath <execution.json>`. Pass the result and SHA-256 to
   `RecordSourceOnlyPublication`, then run current-work validation.

Observation requires `-OperationStartPath`, `-OperationEvidencePath` and
`-ExpectedOperationEvidenceSha256`, alongside the plan and repository map. The
operation executor supplies this compact evidence from the operation it ran:

```json
{
  "schema": "rusty.morphospace.workflow.source_only_publication_operation_evidence.v1",
  "operation_start_sha256": "<SHA-256 of the start document>",
  "provider": {"repo_id": "<planned repo ID>", "executor_id": "<operation executor>"},
  "outcome": {
    "operation_finished_at": "<actual UTC timestamp>",
    "push_mode": "fast-forward", "force_used": false, "result": "pass"
  },
  "artifact": {"path": "operation.log", "sha256": "<SHA-256 of the retained outcome>"}
}
```

Use `false` and `pass` only when the executor's actual command/provider result
establishes them. This is an explicit executor attestation, not independent
proof of execution. The builder binds it to the start document, validates its
artifact relative to the evidence directory, and separately observes the exact
planned remote, final commit, parents and tree. It rejects absent or unknown
outcomes. Keep inputs with private repository identities in private planning.

`Readiness` uses the same isolated, hash-bound Git executable and configuration
environment as the publication observations. It reports repository-local
normalization, attribute hashes and credential-helper availability without
recording credential values. It authenticates Windows physical roots and Git
common directories before reporting a supported layout. A resolver map can
include external instruction/skill support entries: `project.spec.json`
defines project membership, and the unit defines published sources and
read-only dependencies. A support entry does not become a publication target.

`supported` means the inspected layout fits this route; it is not validation,
acceptance or publication permission. `unsupported` gives the incompatible
shape before an owner transition. In particular, each published source must
have a remote delta; declare genuinely unchanged sources as read-only when
admitting the unit. `unavailable` identifies incomplete remote readback, with
any separately observed source/evidence problem retained in `reason_codes`.
Retry the readback with the existing identity; network failure alone is not a
reason to create a unit or repeat source validation.

## Bound publication contract

The plan binds an authenticated accepted owner transition, its schema-valid
passing validation receipt and checkpoint, and each candidate to that receipt's
repository revision snapshot. It also binds the clean local-only planning owner,
exact source repository coverage, remote URL and protected target ref, ordered
old/candidate commits and trees, complete reviewed snapshot paths, and rollback
targets. Trigger-unit paths, when present, stay within the accepted unit's
write scope; carried paths stay within the exact project owner scope. A
carried-only row is valid only when its full candidate diff remains bound to
the accepted validation snapshot.

The plan's acceptance receipt and validation-evidence references are
workspace-relative. Within a `validation_receipt.v1`, relative artifact paths
resolve from the receipt's directory; rooted artifact paths retain their
declared rooted resolution. Every artifact remains bound by its exact raw
SHA-256.

When the accepted event is immediately followed by the exact
[accepted evidence relocation](ACCEPTED_VALIDATION_EVIDENCE_RELOCATION.md),
the plan binds that correction as its prepublication tail while retaining
the original acceptance event and receipt. Each artifact resolves only
through its authenticated same-hash ignored-local mapping. Without that
correction, ordinary receipt-relative and rooted resolution is unchanged.

`fast-forward` binds the candidate as the final ref. `provider-merge` leaves
the future merge revision unset in the plan. Recording accepts it only when
the externally observed merge has exactly two ordered parents: the bound old
protected ref and bound candidate, and when its tree equals the candidate
tree. Both modes require a direct remote readback against the bound URL, clean
sources, no force, declared dependency order, reverse rollback order, and
per-source operation/readback timestamps in that order.

Keep each candidate branch tracking the plan's bound target, such as
`origin/main`. Publish a temporary feature ref explicitly with
`git push origin HEAD:refs/heads/<feature>`; do not use `git push -u`, because
retargeting the candidate's upstream changes its reviewed identity. After a
provider merges the feature ref, fetch the protected target for readback while
leaving the candidate branch and its reviewed HEAD checked out for
`RecordSourceOnlyPublication`.

Preparation writes the immutable plan, pending bundle, and event through the
transition ledger. Recording re-authenticates that exact owner transaction and
consumes only its pending bundle after remote evidence. Either action recovers
only its exact interrupted ledger transaction. The planning repository remains
local-only throughout: no remote, planning ref, or planning-publication claim
is created.

The plan continues to bind the accepted planning HEAD and tree observed before
Prepare. It may also be consumed after one exact local Git checkpoint of the
completed Prepare: the checkpoint must be a single direct child of that bound
HEAD, on the same branch, and contain exactly the native state/event append,
immutable plan, and preparation intent/completion. The owner authenticates
their committed bytes and original preimage against the completed transaction;
it does not accept an arbitrary descendant, extra path, substituted plan or
caller-supplied replacement HEAD. The same finite checkpoint is retained during
exact Record interruption recovery and replay, independently of later live
Record projections. All existing accepted-unit, source, remote, ordering,
worktree-dirt and pending-bundle guards still apply. Checkpointing Prepare does
not authorize repeating an already executed source publication.

Current-work validation recognizes the exact prepared or recorded source-only
tail from its committed transition, schema-valid plan or execution artifact,
retained accepted unit, and bounded state delta. This local history check does
not repeat source remote, ordering, merge-parent, or tree observations; the
source-only writer performs those checks before it commits the transition. It
also does not require a planning transport repository or planning remote.

## Retire a failed, unmerged preparation

Use `RetireSourceOnlyPublication` for one prepared provider-merge source whose
feature push and PR creation succeeded without force, whose required checks
failed, and whose protected target remains unchanged and PR remains open and
unmerged. This is a terminal failure disposition. Do not reopen its accepted unit, rewrite its plan, or use
the distinct legacy `RetirePreparedPush` container format.

Capture the actual current provider pull-request snapshot, then use
`New-SourceOnlyPublicationInput.ps1 -Action Retirement` with `-WorkspaceRoot`,
`-UnitId`, `-RepoMapPath`, the canonical prepared `-PlanPath`,
`-ProviderObservationPaths`, `-FailureEvidencePath`, its reviewed
`-ExpectedFailureEvidenceSha256`, a truthful `-Reason`, and a create-new `-OutPath`.
Keep the failure envelope and original raw files in an explicit ignored local
capsule. The envelope's `capsule_root` is either `local/<capsule>` relative to
the workspace, or `../local/<capsule>` in its immediate project parent. The
owner rejects roots outside these two project-owned local areas, reparse
paths, nonignored roots and nested references outside the declared capsule.
Original nested absolute paths remain valid only inside that capsule; their
bytes are never rewritten or relabeled. Every referenced file and stream
retains its raw byte length and hash. The closed
`source_only_publication_failure_evidence.v1` envelope
binds publication, project, trigger unit, source repository, executor and plan
SHA-256, with `operation_start`, `push_verification`, `pull_request`, and
`required_check_watch` references. Each reference has `path`, `bytes`, and
`sha256`. Retain the actual checked-result shape: exact exit code, original
wait returned, both stream EOF flags, completion, elapsed seconds, and both
stream references. Push and PR must exit zero; the required watch must exit one.
The preserved push verification binds clean before/after candidate, tree,
branch, upstream, remote and before/after refs, force false and unchanged
upstream. This remains an executor attestation of its actual command; remote
readback alone does not prove that command or absence of force.

The one source requires an actual GitHub REST or connector
pull-request JSON snapshot. A bare `merged: false` declaration is not a
snapshot. The input binds its raw path/hash, repository, PR number, exact
head/base revisions and target branch. Fast-forward and multi-source partial
outcomes are outside this bounded operation.

Pass that input to `Invoke-WorkUnitAutomation.ps1 -Action
RetireSourceOnlyPublication -SourceOnlyPublicationRetirement <input>
-ExpectedSourceOnlyPublicationRetirementSha256 <reviewed hash>`, with the same
workspace, unit and map. Dry-run first; execution requires its reviewed hash.
The canonical output is `receipts/<publication-id>-retirement.json`.

The writer reauthenticates the exact accepted unit and prepared transaction,
all current source identities, the project/state/event CAS and each raw
provider snapshot. It directly reads the protected target and pushed feature
ref, requiring the original base and candidate respectively. It also uses the
bound `gh` executable for fresh read-only PR and required-check observations.
The PR must retain its exact same-repository head/base and be open/unmerged;
all required checks must have known terminal outcomes, including a failure.
Unknown, pending, canceled, swapped or changed check evidence is held. Changed,
already published or partly published refs, merged PRs, damaged snapshots,
identity drift and completed cancellation replay refuse. An interrupted
retirement may resume only its exact immutable transaction and input.

Capture the original evidence once; the constructor and writer independently
refresh current provider and Git observations. Retirement performs no provider
or source mutation. Exact input/CAS and fresh readbacks supply its guards.

Retirement appends one truthful `source-publication-retired` transaction and
clears only that pending bundle. It preserves accepted-unit and old-plan
bytes, validation and ledger history. It neither closes the PR nor removes a
feature push, changes a remote, grants publication credit or resolves an
external effect. The receipt retains the observed provider state. Make and
accept any source correction through the ordinary next unit before preparing
a fresh publication plan. Current-work validation authenticates the retired
tail without repeating network observations.

Run `pwsh -NoProfile -File .\scripts\Test-SourceOnlyPublication.ps1 -SelfTest`
for the focused provider-merge, replay, and prepared/recorded current-work
fixture. This check is Windows-only because source/planning alias rejection
uses volume serial and `FileIdInfo` directory identity. Its affected-validation
closure includes the transition ledger, content-observation helper, protocol
common layer, and public automation wrapper.
Run `scripts/Test-SourceOnlyPublicationRetirement.ps1 -SelfTest` for the exact
known-partial failure, adversarial, current-work and four interruption fixtures.
Its provider responses are isolated synthetic fixtures; actual prepare and
retire transactions use the owner writer and local Git remotes. This does not
claim a real provider operation ran during the test.

Also run `scripts/Test-SourceOnlyPublicationInputs.ps1 -SelfTest` when changing
the builders or their shared receipt contract. This rehearsal uses the receipt
producer and real RecordValidation, Accept, preparation and recording actions,
with local-only planning, two ordered source repositories, empty source write
scope, receipt-relative evidence, provider merges and preserved retired history.
The focused recovery suite covers every owner interruption boundary. Neither
fixture turns source publication into build, device, wearer or release evidence.

Local iteration remains distinct from candidate qualification and source
publication. A separately supported private Iteration/DevFast route may bind a
base Git revision plus a hashed overlay for local compile/install and its own
composition checks. These source-delivery records add no Freeze, CI or adoption
prerequisite to that route, and do not relax clean candidate/source guards.

### Recorded source-only integration parent

Reviewed integration may retain a closed `source-only-published-parent` descriptor
through the existing `published_landing` raw-reference slot. It binds the original
owner workspace, unit and repository-map bytes, canonical Plan/Execution and the
completed native Record intent/completion, plus the selected writable repository.
The source-only owner reauthenticates accepted validation and nested artifacts,
exact Prepare/Record semantics and the current committed continuation on every use.
For the supported Prepare-checkpoint case it derives the unique first-parent first
child of the Plan's original planning HEAD and proves the exact five native paths;
missing or ambiguous history is refused. Later legitimate owner commits do not
become authority for a new Record. New Record and incomplete recovery still require
the original planning HEAD or its single exact Prepare checkpoint and exact remote
P. Only a genuinely completed Record can supply a historical parent, whose fresh
remote readback must retain P as an ancestor after normal subsequent publication.

This provenance supplies the owned published commit/tree and repository identity.
It supplies no Landing, historical premerge checks, successor acceptance, product
adoption or device success. Original source-map custody and the separate clean
integration checkout remain distinct. The existing strict Landing branch, accepted
successor delta, native merge computation and later verification remain mandatory.

Reviewed integration retains the exact ordered `check-attr -z` merge-attribute
triples for M, S and P. The three streams must agree on every path. Uniform
`unspecified` remains supported; uniform `unset` is supported only for a regular
file present with identical mode and blob in all three inputs. This permits an
unchanged binary file declared by ordinary tracked attributes without selecting
a merge driver. Changed or absent binary inputs, custom/union/set drivers, and
attribute-inventory changes remain outside this contract. The producer and
retained computation reader apply the same predicate to the original streams.
