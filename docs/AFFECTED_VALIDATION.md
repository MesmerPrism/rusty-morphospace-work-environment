# Affected Validation

`validate.yml` resolves a closed, exact-base/current-head plan before running
candidate validation. The registry owns canonical path classes, semantic
dependencies, execution order, platform applicability, and the exact Git blob identities that evidence
must bind. The focused ownership audit independently enumerates the exact HEAD
tree and requires every tracked path, including every registered command, to
have one path-set owner. A path set must trigger a specialized check in
addition to public-boundary validation. Case collisions and changes to the
affected-validation schemas fail closed to Deep; they do not silently widen a
Quick run. Selector implementation changes stay affected and execute the full
bounded selector self-test closure.

External admission remains mandatory and independent of dynamic test
selection. `.github/workflows/validate.yml` stays in the selector trust root,
while `.github/workflows/static-admission.yml` belongs to the GitHub adapter
surface. Canonical-text, authorization-helper, shared authorization-core,
authorization-test, shared assessment-contract, verifier, and adapter paths
have disjoint owners. A helper change selects canonical-byte,
owner-authorization, and public-boundary checks; a shared authorization-core
change additionally selects the GitHub adapter, historical-debt baseline,
prepared-push reconciliation, and fast authority runner that consume those
bytes. An assessment-schema change selects its signing, verifier, and adapter
consumers. Other verifier changes select verifier and adapter self-tests, while
an adapter-only change stays on the adapter self-test. These focused external
checks are Standard, exact-host trust roots and do not select the cumulative
Work Environment Deep aggregate. Static Admission still applies its
protected-artifact and external-owner policy to every candidate regardless of
the affected-validation plan. The registry itself is a mandatory protected
path. It has a distinct owner from the selector engine: a registry-only change
requires exact static owner admission and selects the bounded ownership and
workflow-action registry checks, but does not select the cumulative Deep suite.
The affected-validation schemas remain the Deep trust root. Selector
implementation changes execute the full bounded selector self-test closure.
This keeps routine additive ownership maintenance reviewable without allowing
candidate-controlled selection data to authorize itself.

The repository-wide ownership migration covers every exact tracked path without
`scripts/**`, `Test-*.ps1`, extension-wide, or miscellaneous catch-alls. It
separates lifecycle corrections, publication owners, Quest adapters, tools,
repository metadata, and example scaffolding. The former two-way preparation
scope overlap is resolved in favor of `preparation-repository-scope`. Every one
of the 22 previously unowned registered commands now belongs to its focused
owner.

Every owner invoked by the cumulative `Test-WorkEnvironment.ps1` suite has an
independent registration. This includes the eleven previously recorded test
debts and `New-ProjectWorkspace.ps1 -SelfTest`, which the former `Test-*.ps1`
inventory silently omitted. The self-test derives table and direct invocations
from the aggregate AST, normalizes only its local `-RepoRoot` injection, and
requires one exact registered command/argument match. Adding another aggregate
owner or drifting its focused arguments therefore fails without updating a
hand-maintained debt count.

The resolver emits plan v2. Plan v1 remains a historical schema and current
resolution, execution, segment merge, and reuse reject it. Each v2 plan binds
the exact base and head registry blob OIDs and carries a versioned registry
delta classification. Old and deleted paths are mapped with the base registry;
new and added paths are mapped with the candidate registry; modified and
renamed paths must map on both sides. An unmapped or ambiguously owned side
produces a canonical `mapping-incomplete` plan with deterministic diagnostics,
no selected checks, zero budget, and `execution_permitted=false`. The selector
job uploads that plan and then fails before a validation segment can start.

An unchanged registry needs no candidate ownership audit. Every changed
registry receives the full candidate ownership and closure audit. A change to
`revision` alone remains bounded only when every other registry semantic is
identical. A coverage expansion remains bounded only when it appends literal
patterns to existing path sets or appends trigger/consume references to
existing checks, removes or mutates nothing, preserves every surviving base
check's execution semantics and dependency closure, and leaves the candidate
with complete unique ownership. All other registry deltas are structural and
select independent Deep leaves. A missing base check obligation is
`mapping-incomplete` unless the resolver emits an exact unreferenced-retirement
proof from the bound base and candidate registries. That narrow proof requires
an exact next revision, a complete candidate ownership audit, no base or
candidate prerequisite or execution-order reference to the removed check, no
surviving consumer of a contract it provided, no always-run or aggregate role,
and no same-invocation replacement. If its command path remains tracked,
another candidate check must still register that command. A proved retirement
remains structural: it selects the independent Deep leaves and still requires
exact static owner admission. Any failed predicate stays `mapping-incomplete`;
the proof never excuses an ambiguous base mapping.

A same-PR mapping migration may repair one previously unmapped old side only
when the changed artifact survives as a modification or rename, the registry
revision is exactly next, the complete candidate tree has unique ownership,
and the candidate path has one path-set owner with at least one trigger. The
plan records the old/new path and change status, the candidate path-set digest,
and every candidate trigger and consumer check bound by the exact head registry.
Those checks remain in the structural Deep selection. Deletes and any base-side
ambiguity remain non-executable `mapping-incomplete` outcomes.

These proofs are the structural intent for retirement and migration. Their
deterministic fields derive from the two registry blobs already bound by plan
v2, while Deep candidate execution and base-owned Static Admission remain
separate. A second general structural-intent or review-exception mechanism
would duplicate those bindings without closing another concrete risk, so the
deferred C14 idea is unnecessary for these cases.

Each resolver call binds the canonical repository root, tracked cleanliness,
HEAD commit/tree, base ancestry, registry/schema identities, and the complete
ordinal command-path set. It consumes one recursive exact-head tree inventory
and one batched `git hash-object --stdin-paths` operation for the registry,
schema, and command working bytes. The returned count, order, paths, tree blobs,
and filtered working blobs must be exact. Root, cleanliness, HEAD, registry raw
bytes, and compiled registry inputs are rechecked across the batch. Missing,
extra, duplicate, case-colliding, malformed, filter-ambiguous, or drifted input
fails closed. No mutable worktree or unchecked path result is cached.

Each selected check either runs in one bounded child process or consumes one
exact reusable passing leaf. Every leaf publishes create-new raw stdout and
stderr bytes plus a closed receipt binding their lengths and hashes, command
and arguments, the command's tracked transitive PowerShell import/invocation
closure, conservatively resolved dynamic imports, tracked schema/manifest/data
inputs, declared consumed exact-head Git blobs, the exact executor/evidence
module/schema source set including the consumed plan schema, the projected
evidence-relevant check definition, runner executable bytes and versions, and
prerequisite binding identities. The raw registry remains bound by full plan
selection validation; scheduling-only `execution_after_checks` metadata is the
only check-definition field omitted from a reusable leaf binding. A
zero-check platform request is invalid. A nonzero exit, timeout, output flood,
or post-kill drain overrun is `code-fail`; `infra-fail` is reserved for a
process-start or host fault. Each failed child carries one closed
`failure_kind` (`launch`, `timeout`, `output-limit`, `drain-timeout`,
`infrastructure`, or `exit-code`), and both raw streams remain length- and
SHA-256-bound. Both write typed leaf and aggregate evidence
before the job fails.

The dependency closure is derived separately for each distinct exact check
input. Checks in the same bounded executor process share the result only when
their head commit/tree, registry digest, command path, and consumed path sets
are identical. Its binding
records the entrypoint, exact ordinal static import/invocation closure, only the
dynamic declarations actually consumed, and any conservative fallback reason.
Dynamic declarations are closed importer/variable/count records and drift in
their count, target, classification, or exact source bytes rejects the leaf.
An invocation that cannot be resolved safely does not borrow another check's
closure: that one leaf binds every tracked PowerShell source and records the
unresolved importer, variable, and kind. Declared consume path sets, runner and
schema sources, prerequisite bindings, and the pre/post source-byte checks stay
independent and exact. This prevents an unrelated ledger-only correction from
invalidating otherwise reusable documentation, skill, or protocol-foundation
leaves while retaining invalidation for real ownership, ledger, and authority
consumers.

Current-run leaf bytes are retained as canonical parent-owned in-memory
snapshots only after the executor's supervisor has published one tagged result
through a parent-created anonymous completion pipe, terminated its complete
owned process containment, and read back zero
remaining contained processes. This cleanup runs for normal exits as well as
failure, timeout, and output overflow. A cleanup or readback failure is an
integrity failure and cannot publish a reusable cache. The parent derives the
leaf terminal only from that non-inherited private pipe; the supervisor OS exit
code and candidate-visible files never carry a terminal decision. The tagged
record distinguishes the complete leaf exit domain (including exit 125) from a
supervisor infrastructure error, and a missing record fails closed even when
the supervisor is forced to exit zero. On Windows, the supervisor removes pipe
inheritance and installs and reads back an exact owner/DACL. The DACL denies
`OWNER_RIGHTS` so ownership cannot imply `WRITE_DAC`, grants full control only
to `SYSTEM` and one deterministic enabled guard-group SID, and contains no
same-user allow entry. Its ordered access check grants the trusted guard before
the owner denial; a leaf cannot match that allow. The supervisor and outer executor retain that group as
enabled; the real same-user leaf is created with the exact guard group converted
to deny-only. A deny-only SID cannot satisfy the guard allow entry, preventing
the leaf from reopening the supervisor/ancestor token for query, duplication,
impersonation, or privilege adjustment or opening the process for owner/DACL
replacement, terminate/injection, or handle duplication. The leaf's complete
source privilege set is also enumerated and its non-allowlisted privileges are
deleted, retaining only `SeChangeNotifyPrivilege` when present. The restricted
token is read back before launch: the guard must be deny-only and any other
retained privilege fails closed;
the damage proof also binds one privilege that existed in the source token and
proves it cannot be re-enabled in the leaf. Before candidate code starts, the
supervisor protects the exact two-process evidence-authority chain: itself and
its direct parent executor. Unrelated desktop, shell, and system ancestors are
outside that authority chain and are neither modified nor claimed. The process
objects, every accessible existing thread object, and both processes' token
default DACLs receive the same protected owner/DACL policy. Fresh supervisor
and outer-parent sentinel threads are then created from the protected default
DACLs, and the exact
leaf token must fail every process and thread query, terminate, injection,
handle-duplication, owner, and DACL open against both authorities and all their
observed threads. Threads that were already access-denied to the trusted parent
are not mutated, but remain in this leaf-token denial probe. The supervisor and
trusted outer executor independently retain the exact original bytes for every
object they mutate and an exact pre-protection default-thread descriptor
template. They retain the exact initial thread identities and their open
handles through cleanup, restore the token defaults first, restore captured
process and existing-thread descriptors, then repeatedly enumerate and restore
only non-initial threads carrying the protected DACL until the thread set is
stable. Handles for every classified late thread remain open during that scan,
so thread-ID reuse cannot alias an exited object; already-restored identities
also make the protected-DACL-equals-original-template case terminal rather than
an endless reclassification. Both sentinels and every retained object are read
back byte-exact before a terminal can be published. The outer
copy is captured after the completion drains are live and survives supervisor
termination, timeout, and setup failure. The leaf therefore cannot target an
unprotected evidence-producing authority thread, including one created after
the initial process protection, or re-enable a removed source privilege to
bypass a descriptor. The supervisor creates that restricted leaf
suspended with bounded
stdout/stderr pipes, assigns it to a non-breakaway inner job, and resumes it.
It streams at most 10 MiB combined while the leaf runs, terminates the job at
the first excess byte, and reads back zero job members before publishing the
tagged result. It never stages unbounded output files or performs an unbounded
post-run allocation. On Linux, the supervisor uses noninteractive trusted-host
elevation only to create a fresh PID namespace through `unshare`, then `setpriv`
immediately returns the real leaf to the original UID/GID; the leaf runs as PID
1. The namespace is a bounded process-cleanup boundary, not a privilege authority
boundary: hosted candidate jobs already have ambient noninteractive `sudo`, and
nested executor-containment self-tests must be able to create child namespaces.
Session or process-group changes remain inside that namespace, whose teardown
kills descendants before the stream pumps must drain. Missing `sudo`, `unshare`,
`setpriv`, noninteractive elevation, namespace support, or UID/GID-drop
support is an infrastructure failure before candidate execution. The outer Windows job
or Linux supervisor group plus a direct process-tree kill/readback is retained
as a setup- and timeout-failure fallback. No passing terminal is possible until
the contained descendants are gone and both leaf streams are complete. The
final check-cache root remains absent
while any candidate child can run. Only after every selected leaf has a typed
outcome does the parent create that root and materialize the retained receipts,
streams, and bound inner artifacts with create-new writes before publishing the
inventory. The parent then rereads every expected file twice, verifies exact
length, SHA-256, and bytes against the retained snapshots (including the
inventory itself), and returns that inventory SHA-256 to the workflow. Artifact
upload and cache save require exact equality with the returned digest. A later sibling therefore cannot rewrite an earlier failure into a
self-consistent pass or drift an earlier stream; precreation or collision makes
the cache non-finalizable and publishes no reusable inventory.

Reusable leaves come only from the same PR-scoped platform cache and are an
optimization input, never authority. The current executor revalidates their
closed schema, binding digest, complete raw streams, source commit/tree and
ancestry, every recorded blob at that source commit, exact runner, cache
policy, and every prerequisite binding. Before any child starts, the parent
reads one closed producer inventory, validates its repository/PR/workflow
provenance and every listed file, enumerates all candidate receipts, and
snapshots every accepted receipt/stream into memory. Candidate receipt paths
are compared ordinally. Reuse requires exactly one valid binding; duplicates
reject instead of selecting by filesystem order. Receipt and stream bytes are
read once through non-reparse ancestry, validated, and copied from those same
immutable in-memory bytes so later path drift cannot change the result. Disabled
or external-state checks always execute. Accepted prior streams are copied
into a new self-contained `reused` receipt for the current run; damaged,
stale, missing, or drifted cache entries are ignored and the check executes.
The current artifact therefore remains sufficient even if the cache expires.

Immediately before and after every executed child, the parent verifies a clean
exact HEAD and batch-hashes the complete runner and leaf dependency set back to
the bound Git blobs. It never edits the process-global environment. Instead it
hashes the complete parent name/value byte projection before and after launch,
builds the supervisor environment from empty, and admits only reviewed
OS/runtime variables, launcher-owned `RUSTY_AFFECTED_VALIDATION_*` variables,
and the exact read-only hosted producer identity. `GIT_*`, GitHub command-file
channels, unrelated `RUSTY_*`, and all other ambient variables are absent. The
phase runner independently clears and rebuilds its own child environment, and
the Linux privileged namespace path uses `env -i`, so neither second hop can
re-expand ambient state. Each executed receipt binds ordinal variable names,
sources, per-value hashes, counts, supervisor projection hash, observed leaf
projection hash, and equal parent before/after hashes; a pre-projection or
blocked path binds null hashes, zero counts, and empty lists. Source drift is a typed infrastructure failure:
remaining leaves do not start and no reusable inventory is finalized. A
create-new collision or incomplete execution likewise publishes no cache.

Checks execute in deterministic dependency order. `prerequisite_checks` are
semantic evidence dependencies: they are selected with their consumer, enter
the consumer binding, and block the consumer when they fail.
`execution_after_checks` are scheduling edges only: they order two checks when
both are already selected, but they neither select the later check nor enter
its reusable-evidence binding, and a failed ordering anchor does not block it.
The registry rejects unknown, cross-platform, duplicate, cyclic, self, or
contract-carrying scheduling edges; a consumed contract must remain a semantic
prerequisite. A failed leaf therefore blocks only its transitive semantic
dependents, which receive explicit create-new `blocked` receipts; independent
leaves continue and preserve their evidence. A corrected attempt may then
reuse every still-valid independent pass instead of replaying the entire
platform gate.

Development admission, admission-timestamp recovery and recovered-proposal
continuation are separate Windows leaves. Each direct test path selects only
its owner test and the public boundary; the composed continuation helper has
that same narrow route. Their plain shared admission fixture selects admission
and continuation. Production admission and recovery paths remain separate from
test paths and invalidate their declared consumers. The selector's proportional
mapping cases assert these exact test-only selections, including rejection of
unrelated suite expansion. The existing per-check dependency closure still binds
all imported code and consumed data; splitting a trigger does not remove an
actual input from reusable evidence.

Selection and reuse have different limits. The continuation's generic automation
route reaches authority-artifact lists that the static scanner conservatively
treats as script dependencies, including owner tests skipped at runtime. Its
dependency manifest can therefore retain the all-script fallback even though
its trigger and execution are separate. This does not expand its trigger sets,
but can invalidate reuse after an unrelated script edit. Keep that fallback
until a reviewed scanner or call-boundary change proves narrower inputs; do not
hide internal dispatch with an external-command declaration or alternate API.
Preparation's two opaque module-context calls have exact importer, count and
target declarations, so that check no longer needs the all-script fallback.

The continuation leaf owns the sequence whose steps depend on each other:
writer-produced admission, timestamp recovery, proposal retirement and fresh
preparation. A direct rerun reconstructs its required seed without replaying
the other admission tests. Full explicit compatibility aggregates retain that
case once; affected CI uses its separate result. Keep previous passing leaves
only through the existing authenticated reuse route, and report a diagnostic
focused pass separately from a completed frozen-candidate aggregate.

Selector trust-root validation is a finite twenty-eight-phase DAG: graph/import
closure, independently reusable per-check dependency-closure damage, executor
pass/schema, ten independent executor-damage leaves for native failure,
native exit 125, forged terminal control, parent containment, descendant
containment, output ceiling, timeout, dual-stream draining, source integrity,
and publication collision,
selection scenarios, then sibling trust leaves for the phase-runner artifact
contract and selector/executor integration. The artifact-contract leaf validates
the schema-valid phase receipt and exact artifact set. The `trust-self-executor`
leaf proves exact full-plan selection plus platform, prerequisite and contract
closure without replaying that full plan, then runs an unmodified plan naturally
resolved from a separate two-check fixture through the production executor.
Further independently reusable trust leaves cover registry
delta/ownership/obligation, Linux and Windows Deep partition/merge damage,
bounded archive/development/retirement/automation routing contracts,
proportional mappings, and damage/culture finalization.
Three further leaves partition reuse admission, evidence binding, and
run-job/coverage validation; the legacy reuse self-test retains only its bounded
compatibility check and does not replay those bodies. Each phase has its own
finite child budget and exact-host cache policy, so a later failure in one
trust leaf does not invalidate completed sibling evidence. The measured
artifact-contract phase was 16.895 seconds (19.331 seconds wall) under its
75-second inner and 90-second outer budgets; selector/executor integration was
71.759 seconds (74.069 seconds wall) under its 90-second inner and 105-second
outer budgets. Every phase has a
create-new terminal receipt bound to the exact repository commit/tree,
plan, platform, check identity, and exact dependency manifest. The outer
executor derives and batch-verifies that registry-owned transitive closure once
per identical head/tree, registry, command, and consumed-path-set input group,
then publishes its canonical bytes through a create-new temporary file held
read-only by the parent for the complete child lifetime. The child receives
only its path and parent-computed SHA-256, then validates the projection schema,
current head/tree, registry and check identity, ordinal tree records, and
working bytes; it never repeats the import-graph analysis. The parent rechecks
the held projection after the child and removes it during bounded cleanup.
The registry contract requires all twenty-eight phase checks and the complete
verifier to share that exact command and consumed-path-set input. The historical
eighteen-phase verifier remains unchanged for compatibility; the complete
verifier depends on every added phase and accepts only the full terminal set.
Each phase still receives
and verifies its own check identity and binding, and the grouped working-byte
set is rechecked after all terminals are consumed. Runner identity additionally
binds the current OS/process architecture plus exact PowerShell and Git
executable bytes and versions.
The outer executor is the sole completeness owner for this projection: it
passes the same manifest already committed to the enclosing leaf binding, and
the phase child may validate but never add, omit, or substitute records. A
phase terminal is therefore non-authoritative on its own and is consumable only
through an enclosing affected-check receipt whose exact dependency manifest is
equal. Omission, addition, order, tree, working-byte, registry, or check-input
drift fails before phase evidence can be accepted.
The terminal verifier
accepts only the complete exact passing receipt set and never replays a phase.
Hosted outer affected CI still executes the selected phase leaves and retains
their typed terminal and enclosing evidence bindings.
Each executor-damage leaf begins from the same immutable fixture head and has
no sibling mutation dependency. Selection consumes all ten contracts, while
an individual failure leaves completed sibling receipts reusable. The executor
stops at the first failed selector phase. A later attempt may
reuse an exact passing terminal already materialized under the deterministic
plan/platform phase root; drift, collision, malformed evidence, missing raw
streams, or a changed dependency binding fails closed. This is iterative
escalation and evidence reuse, not a larger cumulative timeout.

For an exact-host selector phase, the outer leaf receipt and inventory also
bind the phase start, terminal, raw streams, and every terminal-referenced
output as closed inner artifacts. A fresh retry snapshots these bytes from the
prior parent inventory, requires their exact authenticated receipt-source
head/tree binding, and rehydrates missing phase files with create-new writes
only after the complete existing destination ancestry up to the volume root is
free of reparse points. The verifier accepts an ancestor-source
phase only when its repository/platform/check/phase identity, exact runner,
and complete dependency manifest equal the current expectation and Git proves
both its source tree and ancestry. The enclosing receipt's required
`plan_sha256` is the phase's original plan identity, not the retry's scheduling
plan; plan and head provenance therefore remain the original source evidence. A reused receipt retains that original evidence source
transitively while the enclosing inventory records the current run. Runner/dependency drift, a wrong tree, a nonancestor, or a
differing collision is preserved and fails closed. The verifier can therefore
consume unaffected siblings after one branch failed without relying on an
un-restored workspace directory or replaying those siblings.

PR runs preserve content-addressed plan and aggregate evidence, the complete
parent-materialized per-check stream/receipt/inner-artifact directory, and the selector phase directory. The
platform cache restores only the immediately available candidate material;
the executor, not the cache key, decides whether any leaf is reusable. The
parent writes `inventory.json` only after every selected leaf has a terminal
receipt. Ordinary code failure may therefore preserve completed independent
passes and explicit blocked dependents, but cache upload is conditional on that
finalized inventory; integrity, transport, collision, and partial-execution
failures cannot publish reusable bytes. A main push
may reuse them only when its ordered merge parents, exact candidate tree,
workflow bytes, ancestor base, PR/run/check identities, artifact bytes, and
freshness all authenticate through `Test-AffectedValidationReuse.ps1`.
The authenticated successful-job set is exactly `infrastructure`,
`quick-linux`, `quick-windows`, `select`, `standard-windows`, and the
deterministically recomputed `segment-<platform>-<ordinal>` jobs for selected
platforms; artifact aliases such as `affected-linux` and `affected-windows`
never substitute for GitHub job identities. Otherwise the main job runs its
current delta through the same segment partition. No historical Deep receipt
is reusable: scheduled/manual Deep checks out full history, executes every
independent leaf through fresh segments, and verifies their exact union.
Neither evidence shape is publication or acceptance authority.

Segment retries retain earlier artifacts in the same GitHub run. Each segment
artifact name binds its segment ID, raw payload SHA-256, run ID, and attempt.
All four platform reducers download those artifacts into separate directories
and use `Stage-AffectedValidationSegmentEvidence.ps1` before the strict segment
merger. Flattening multiple artifact attempts into the same filenames is
forbidden: download order must never choose a validation result.

Staging selects exactly one candidate at the greatest available attempt no
later than the current attempt for every expected segment in the same run.
Unchanged siblings may come from earlier attempts. A duplicate winner, missing
segment, foreign run, future attempt, unsafe payload layout, wrong digest,
source/plan mismatch, or non-passing selected result rejects; it never causes
fallback to an older pass. Superseded results do not enter the merged
validation result.
Outputs must be new paths outside Git metadata, with no input overlap or
reparse-point ancestors. All selected bytes are checked before create-new
staging, and a closed selection receipt records artifact names, attempts and
digests. The existing merger
then verifies the exact plan, runner, ordered coverage and command blobs.

This transport selection is valid only behind the reducers' successful-producer
guards. Every successful producer must upload its exact evidence, and neither
execution nor upload may use `continue-on-error`. A retry that fails before
upload, times out, or is cancelled cannot borrow an older passing artifact.
These guards apply equally to pull requests, scheduled/manual Deep, and push
delta reducers. Selection receipts are retained for diagnosis; they grant no
aggregate, acceptance or publication authority.

Plans and final Linux/Windows aggregates also include run ID and attempt in
their artifact names, permitting aggregate-only and complete workflow retries.
The plan name continues to bind the canonical plan digest; evidence names bind
raw file digests. Post-merge attestation enumerates all artifact pages and uses
the same deterministic attempt selector before downloading each logical
artifact. The selected names are bound to the successful PR run by the reuse
verifier. Expired, damaged or ambiguous winning artifacts require current-delta
validation; they cannot select an older attempt instead. Content-only legacy
names are not admitted by this retry transport contract.

Segment reducers use `Download-AffectedValidationSegmentArtifacts.ps1` to
list the exact run's artifact metadata within a bounded inventory, select the
latest attempt for each logical segment, and download each winner into its
actual artifact-name directory. An expired losing attempt is irrelevant; an
expired winner fails without fallback. Explicit per-name download destinations
preserve identity for both one and many segments: the hosted download action
flattens a single pattern match even with `merge-multiple: false`. Staging still
requires the exact plan's segment set, artifact names, and payload hashes.

The independent `affected-artifact-transport` check exercises real staging
and merging against a small Git fixture on both runner platforms. It owns
retry ordering, retained siblings, identity damage and output-confinement
cases, with its own timeout and exact-host cache binding. Existing selector
and platform-merge phases retain their separate budgets.

Workflow concurrency has four closed identities: a cancelable per-PR group, a
noncanceling main-ref group, a stable noncanceling scheduled Deep group, and a
unique noncanceling manual Deep group bound to `github.run_id`. GitHub may
coalesce an older pending main or scheduled run, while an explicitly requested
manual frozen-candidate Deep run is never replaced and may overlap another run.
Exactly the 21 job and step guards that must remain eligible after an ordinary
prerequisite or step failure use `!cancelled()`: admission of the
`affected-linux-segments` and `affected-windows-segments` jobs,
Quick/Standard/Deep binding or reduction, and conditional diagnostic, evidence,
or cache preservation. Cancellation makes those guards false so no unrelated
segment or reducer is launched or retained. The
`main-linux-segments`, `main-windows-segments`, `main-linux-delta`, and
`main-windows-delta` job conditions retain implicit `success()` semantics and
remain failure-sensitive; they do not use a `!cancelled()` job override. Cancel
a run normally first. Force-cancel only a legacy or already-started run that
does not stop after bounded observation; force-cancel may prevent terminal
evidence upload, and missing evidence never becomes pass or reusable evidence.
Every job has an explicit outer timeout. Segment matrices derive their
timeout from the exact segment estimated budget plus 900 seconds of bounded
setup/cleanup overhead and reject any value reaching GitHub's six-hour ceiling.
Setup, plan, and main-delta pre-evidence failures write create-new diagnostics
bounded to 64 KiB and upload them under the existing pinned artifact action;
they remain explicitly non-authoritative.

Every JavaScript action in this workflow is pinned to an immutable Node 24
release commit. Artifact upload keeps the default archived transport, and all
segment downloads use separate artifact directories and explicit staging; the action
upgrade does not opt into direct-file upload or change the evidence filenames,
payloads, or repository-computed digests. The cache key and cached-directory
contracts are likewise unchanged. These jobs use GitHub-hosted runners, which
satisfy the Node 24 action runner floor; adding a self-hosted runner requires a
separate compatibility decision.

The pre-job infrastructure classifier observes the closed `git`, `pwsh`, and
`rg` set, but requires only `git` and `pwsh` for the registered PR commands.
`rg` is optional at this boundary. A second missing required tool state fails
as `pending-infra`; the workflow records no false success. Hosted zero-job/startup
incidents are observed externally and handed off read-only, because no job can
reliably observe its own absence. See
`scripts/Test-AffectedValidation.ps1` for portable damage fixtures. Selector
trust-root PRs also run the bounded topology and reuse self-tests through the
same affected-validation executor.

Changes limited to the affected-validation registry require its exact external
static owner admission plus the bounded ownership, workflow-action-registry,
public-boundary, and dependency closure selected by the candidate registry.
Changes to the affected-validation schemas still require one-time Deep leaf
admission because those trust-root contracts cannot proportionally approve
themselves. The cumulative `Test-WorkEnvironment -Tier Deep` check has the closed
`aggregate_role: work-environment-deep-v1`; no other check identity or command
may use that role. Trust-root fallback does not run it after selecting all of
its independently evidenced leaves. It remains selected when its own command
or aggregate path changes; an explicit Deep request selects the independent
leaves and does not replay that cumulative aggregate. Hosted execution packs
dependency-connected checks into deterministic, non-overlapping segments with
a one-hour estimated target, runs independent segments concurrently, and then
verifies their exact union into the existing platform evidence shape. A single
dependency component may exceed the target but must remain below the five-hour
hard ceiling; the explicit 15-minute outer overhead keeps every admitted
segment below the hosted six-hour job limit.
After
adoption, changes limited to either APK run-transaction schema or its audit
tool select the portable Quick `apk-run-transaction` leaf plus the public
boundary, without selecting the cumulative Deep aggregate. The authority and
historical-debt paths named in the
registry stay proportional: direct test changes select their owning leaf;
historical phase receipt/module changes select the focused phase-runner,
baseline, and automation consumers, while a phase-runner test change selects
only its direct focused leaf; ownership and validation-authority module changes select their
direct authority consumers; the transition-ledger module has its own exact
path set and selects its focused ledger, blocked-terminal, active-unit,
development-admission, and ordinary automation consumers without overlapping
generic automation; and the shared protocol module selects every
transitive Work Environment owner consumer through an independently derived
tracked-byte graph. The audit AST-classifies both direct invocations and
table/list `script` entries, closes conditional literal and statically bound
`.ps1`/`.psm1` imports, ampersand invocations, and dot sources for every visited
script or module. It conservatively includes ordinal-distinct tracked static
paths handed to nested child launchers and accepts dynamic tracked or
authenticated-external calls only through an exact
importer/variable/count/target-or-classification declaration. Literal,
variable, graph, and consumer identities use ordinal uniqueness and ordering.
For each graph invocation, the audit parses each graph node once and builds one
non-reusable analysis index bound to that repository-relative path and captured
working-byte SHA. A demand-discovery pass first identifies exact command,
variable, and member consumers; a binding pass then inspects only those
assignment/member subtrees, while retaining every assignment containing a
literal script path for conservative closure. The index closes exact lexical
scopes, member tables, typed parameters, and
literal/import/invocation/dot-source candidates and is discarded after
adjacency construction. The audit rechecks every source
byte identity, binds deterministic adjacency and consumer digests, then
memoizes owner reachability under a measured finite timing bound. A
consumer fails closed if it lacks a registered `protocol-common` check. The
selector phases enforce their finite budgets independently; timeout or
over-budget execution fails that phase and never silently escalates to Deep.
The legacy no-argument cumulative selector remains diagnostic only and is not
an admission gate.
The independently reviewed `Test-InheritedCandidateMaterialization.ps1`
receipt is retained as one explicit supplementary consumer because it is not
currently a `Test-WorkEnvironment.ps1` entrypoint. Exact command/import/input closure
remains the evidence-reuse boundary, so an unchanged authenticated leaf may be
reused rather than blindly replayed. The runner-fast clean-room fixture is a
separate exact path class. None of these mapped paths selects
`Test-WorkEnvironment.ps1`; the cumulative aggregate is selected only when its
own registered command or aggregate path changes.

The selector's automation, unmapped-script, owner-command, unknown-path,
rename, repeat, no-change, and delete scenarios can emit create-new start,
terminal, failure, and reuse receipts under an explicitly selected absolute
evidence root. Each receipt binds the selector/resolver bytes, fixture
registry/schema bytes, exact base/head trees, tool versions, result identity,
and per-scenario timing. An exact prior passing terminal can skip only its
identical scenario; damaged, duplicated, drifted, or colliding evidence rejects.
These local receipts are diagnostic and non-authoritative: they neither admit a
candidate nor replace fresh hosted validation.

History-archive contract changes select bounded public-boundary,
workflow-contract, and archive-checkpoint validation without selecting the
historical Deep aggregate. Quick verifies an installed checkpoint's root,
raw-object hashes, ledger prefix, carry-forward references, and live tail;
damage or an unknown pre-checkpoint reference requires archived replay. Deep,
audit, and migration select that replay. This mechanism does not create or
reuse a historical-validation-debt baseline. See
[History Archive Checkpoints](HISTORY_ARCHIVE_CHECKPOINTS.md).

The archive public-router paths select the same archive checkpoint closure plus
the ordinary automation integration check. They remain a distinct path set, so
they cannot be mistaken for generic automation or cause an ambiguous Deep
escalation.

Active-unit supersession and blocked-successor preparation each have one
closed, non-overlapping path set for their request/receipt schemas, owner
module, and focused self-test. Both select the ordinary workflow-contract and
work-unit-automation prerequisites before their Windows Standard owner leaf.
The blocked-successor leaf additionally requires the development-envelope and
normal-validation-selector leaves because it authenticates a prepared
successor and releases only the exact terminal Quick selection. These routes
remain independent checks: a failure blocks only its semantic dependents, and
unchanged passing prerequisites remain eligible for exact dependency-closure
reuse. Prerequisites bind those exact receipts without registering every
dependent as an unconditional reverse consumer of a shared contract; a generic
workflow or automation change therefore cannot fan out into inactive lifecycle
owners. The shared lifecycle routing document remains in the existing
`documentation` path set rather than acquiring a second owner.
Proposed-unit retirement has a Windows Standard exact-host leaf for its closed
receipt schema, typed owner, focused test, and the four retirement readers.
The focused leaf covers both the unchanged direct admission-tail route and the
closed admitted `Ready`/`WithdrawReady` provenance route, including historical
readback and recomputed-hash receipt-ownership forgery rejection.
The production owner/schema and focused test use separate path sets. An owner
or schema change selects the focused leaf, admission and recovered-continuation
consumers, and the broad WorkUnitAutomation consumer with its workflow-contract
prerequisite. A focused-test-only change selects the leaf and public boundary
without invalidating those consumers. The owner imports only protocol common,
transition ledger, and admission recovery. It does not import validation
authority, generic workflow contracts, WF005, or generic automation. The
generic automation route remains broad because it constructs the legacy
compatibility envelope before the typed owner validates and commits it; its
broad test preserves the legacy public timestamp and module/CLI byte contract.
An unrelated validation-owner or self-test change does not invalidate the
focused retirement leaf.
Historical supersession compatibility has its own closed path set for the v1
proof schema, builder, action module, verifier, and focused self-test. It
selects the fast automation-receipt compatibility and workflow-contract
prerequisites before its Windows Standard owner leaf. Its positive fixture
uses the separately mapped event-ledger normalization owner; that dependency
does not place normalization under compatibility ownership. Development-envelope
preparation consumes that leaf because it is the only downstream owner allowed
to interpret an installed proof as the exact transactionless and legacy-v1
two-edge closure. Changes to unrelated lifecycle owners do not select this
exception, while changes to the exception cannot bypass preparation coverage.
The public automation router is covered by a low-cost capture seam in the
ordinary automation integration test. It proves exact dry/execute/replay
forwarding for both lifecycle actions without replaying either focused owner;
the focused owners remain responsible for the real state-transition and
idempotence semantics. Local development can invoke only that seam with
`Test-WorkUnitAutomation.ps1 -LifecycleRouterSelfTestOnly` only as a strict
low-level diagnostic from an already-closed process environment; the
registered owner still runs the complete integration test once for final
admission. The public local Standard route is
`Test-WorkflowContracts.ps1 -StandardDeltaOnly`, whose launcher constructs
that closed child environment without changing its caller.

`terminal-validation-selection-release-v2.schema.json` belongs to the normal
validation selector path set. The shared
`work-unit-automation-receipt-v2.schema.json` and its focused compatibility
test have one separate, non-overlapping path set; generic automation contains
only `WorkUnitAutomation.psm1`. Either path set selects the fast
`automation-receipt-v2-compatibility` check. That check keeps an exact closed
action-to-transition corpus for all v2 schema values, binds every action to its
tracked producer and focused owner test, and schema-validates a producer-shaped
canonical receipt for every allowed pair. The shape table preserves the sole
absent pre-status (`AdmitDevelopmentUnit`), idle/blocked/archive null-current
forms, the supersession dry-run form, and ordinary receipt versus archive
checkpoint paths. Valid-schema cross-pair and nullability damage must still be
rejected by the compatibility owner. The check also invokes the private Ready dispatcher
and selector-binding guard for ordinary-v1, blocked-successor-v2, malformed,
ambiguous, absent-selector, and self-bound-selector cases. A receipt-schema-only
change therefore selects that focused owner and public-boundary validation,
without selecting the normal selector, full automation integration, an archive
checkpoint, development-envelope owner, inactive lifecycle owner, or cumulative
Deep. A `WorkUnitAutomation.psm1` change still selects its existing integration
consumers as well as the fast compatibility owner.
Archive schemas and the archive router still trigger the W-017B archive
checkpoint directly, so retiring reverse workflow-contract expansion does not
weaken the separate archive-envelope route. The
blocked-successor test's retained-module invocations are closed by one
case-insensitive PowerShell-variable declaration with exact ordinal target
paths for its preparation, protocol, and transition-ledger modules. Its actual
dry-run/generated/executed v2 results are checked against the shared receipt
schema. Active-unit supersession also validates its emitted result before
returning; development-envelope preparation and development-unit admission
validate their real dry/executed receipts in their owner suites. The fast
compatibility check does not claim to execute unchanged historical producers:
producer source changes continue to select their focused owners, while a
schema-only change gets a bounded complete producer-shape compatibility pass.
The active-supersession test resolves its literal
module bindings without a dynamic declaration. Every lifecycle path therefore
has one ordinal owner and avoids unmapped or ambiguous Deep fallback.

Development-unit admission has a dedicated, non-overlapping path set for its
schema, module, and focused self-test. Direct changes to any of those paths
select the admission owner and public-boundary validation, but do not replay
development-envelope preparation or the cumulative Deep aggregate. Shared
protocol or transition-ledger changes still select admission through its
declared consumed dependencies.
