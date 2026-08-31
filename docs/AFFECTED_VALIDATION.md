# Affected Validation

`validate.yml` resolves a closed, exact-base/current-head plan before running
candidate validation. The registry owns canonical path classes, prerequisite
order, platform applicability, and the exact Git blob identities that evidence
must bind. Unmapped paths, case collisions, selector/workflow changes, and external
authority changes fail closed to Deep; they do not silently widen a Quick run.

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
module/schema source set, registry check definition, runner executable bytes
and versions, and prerequisite binding identities. A
zero-check platform request is invalid. A nonzero exit, timeout, output flood,
or post-kill drain overrun is `code-fail`; `infra-fail` is reserved for a
process-start or host fault. Both write typed leaf and aggregate evidence
before the job fails.

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
immediately returns the real leaf to the original UID/GID with `no_new_privs`;
the leaf runs as PID 1 and cannot regain the namespace creator's privilege.
Session or process-group changes remain inside that namespace, whose teardown
kills descendants before the stream pumps must drain. Missing `sudo`, `unshare`,
`setpriv`, noninteractive elevation, namespace support, or privilege-drop
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
the bound Git blobs. GitHub output/environment/path/summary channels are
removed from the child process. Source drift is a typed infrastructure failure:
remaining leaves do not start and no reusable inventory is finalized. A
create-new collision or incomplete execution likewise publishes no cache.

Checks execute in prerequisite order. A failed leaf blocks only its transitive
dependents, which receive explicit create-new `blocked` receipts; independent
leaves continue and preserve their evidence. A corrected attempt may then
reuse every still-valid independent pass instead of replaying the entire
platform gate.

Selector trust-root validation is a finite eight-phase DAG: graph/import
closure, executor pass/schema, executor damage, selection scenarios, then four
independent trust leaves for self/executor closure, routing contracts,
proportional mappings, and damage/culture finalization. Each phase has its own
finite child budget and exact-host cache policy, so a later failure in one
trust leaf does not invalidate completed sibling evidence. Every phase has a
create-new terminal receipt bound to the exact repository commit/tree,
registry, schema, runner, selector, affected-validation module, shared
protocol module, plan, platform, check identity, and current OS/process
architecture plus the exact PowerShell and Git executable bytes and versions.
The terminal verifier
accepts only the complete exact passing receipt set and never replays a phase.
The executor stops at the first failed selector phase. A later attempt may
reuse an exact passing terminal already materialized under the deterministic
plan/platform phase root; drift, collision, malformed evidence, missing raw
streams, or a changed dependency binding fails closed. This is iterative
escalation and evidence reuse, not a larger cumulative timeout.

For an exact-host selector phase, the outer leaf receipt and inventory also
bind the phase start, terminal, raw streams, and every terminal-referenced
output as closed inner artifacts. A fresh retry snapshots these bytes from the
prior parent inventory, requires their exact current head/tree binding, and
rehydrates missing phase files with create-new writes before the terminal
verifier runs. Existing identical bytes are accepted; differing collisions are
preserved and fail closed. The verifier can therefore consume unaffected
siblings after one branch failed without relying on an un-restored workspace
directory or replaying those siblings.

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
Otherwise the main job runs only its current delta. No historical aggregate
receipt is reusable: scheduled/manual Deep checks out full history and runs the
current Deep aggregate. Neither evidence shape is publication or acceptance
authority.

The pre-job infrastructure classifier observes the closed `git`, `pwsh`, and
`rg` set, but requires only `git` and `pwsh` for the registered PR commands.
`rg` is optional at this boundary. A second missing required tool state fails
as `pending-infra`; the workflow records no false success. Hosted zero-job/startup
incidents are observed externally and handed off read-only, because no job can
reliably observe its own absence. See
`scripts/Test-AffectedValidation.ps1` for portable damage fixtures. Selector
trust-root PRs also run the bounded topology and reuse self-tests through the
same affected-validation executor.

Changes to the affected-validation registry or its schemas require one-time
Deep leaf admission because that trust root cannot proportionally approve
itself. The cumulative `Test-WorkEnvironment -Tier Deep` check has the closed
`aggregate_role: work-environment-deep-v1`; no other check identity or command
may use that role. Trust-root fallback does not run it after selecting all of
its independently evidenced leaves. It remains selected when its own command
or aggregate path changes and for an explicit Deep aggregate request. After
adoption, the authority and historical-debt paths named in the
registry stay proportional: direct test changes select their owning leaf;
historical phase receipt/module changes select the focused phase-runner,
baseline, and automation consumers, while a phase-runner test change selects
only its direct focused leaf; ownership and validation-authority module changes select their
direct authority consumers; and the shared protocol module selects every
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
`Test-WorkEnvironment.ps1` unless the affected-validation trust root itself
also changed or Deep was explicitly requested.

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
