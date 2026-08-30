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

Each selected check runs in one bounded child process. Its exit code, timeout,
and stdout/stderr hashes and byte counts are recorded in typed evidence. A
zero-check platform request is invalid. A nonzero exit, timeout, output flood,
or post-kill drain overrun is `code-fail`; `infra-fail` is reserved for a
process-start or host fault. Both write typed evidence before the job fails.

Selector trust-root validation is an ordered five-phase DAG: graph/import
closure, executor pass/schema, executor damage, selection scenarios, and
trust/mapping finalization. Each phase has its own finite child budget and
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

PR runs preserve content-addressed plan and evidence artifacts plus the
selector phase directory. A main push
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
Deep admission because that trust root cannot proportionally approve
itself. After adoption, the authority and historical-debt paths named in the
registry stay proportional: direct test changes select their owning leaf;
historical phase receipt/runner changes also select the baseline and automation
consumers; ownership and validation-authority module changes select their
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
