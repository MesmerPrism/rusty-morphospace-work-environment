# Rusty Morphospace Work Environment

Portable onboarding and project-iteration workspace for Rusty Morphospace
development.

PowerShell `7.6` LTS or newer, invoked explicitly as `pwsh`, is the supported
workflow host. Windows PowerShell 5.1 may run the bootstrap host check, but it
is not an execution environment for validation, automation, builds, or release
tooling. PowerShell 7 installs side by side with 5.1 on Windows.

Current work-environment protocol release: `0.6.0` (2026-07-23). It adds
hash-bound adoption of immutable terminal work, exact planned and unplanned
publication accounting, protected-branch source resolution, and bounded
recovery for already-published planning suffixes. Its machine-readable release
surface is the [0.6.0 manifest](manifests/release-0.6.0.json); the principal
operational entrypoints are
[Historical Unit Adoption](docs/HISTORICAL_UNIT_ADOPTION.md) and
[Planned Publication Accounting](docs/PLANNED_PUBLICATION_ACCOUNTING.md).
The release also carries opt-in Quest Accessibility watchdog routing while
preserving managed provisioning as the preferred kiosk lifecycle. It does not
change the separately governed Rusty Morphospace platform/runtime baseline.

The published [0.5.0 manifest](manifests/release-0.5.0.json) remains the
project/source/build/run isolation baseline, and the
[0.4.0 manifest](manifests/release-0.4.0.json) remains the immutable
release-capsule and local-skill onboarding baseline. Earlier manifests remain
readable. Existing project instances adopt later baselines additively:
preserve live events and receipts, normalize portable change categories while
retaining domain detail in `tags`, and validate before using the optional
automation CLI.

Terminal historical units with legacy workflow vocabulary use the explicit
[historical unit adoption contract](docs/HISTORICAL_UNIT_ADOPTION.md). Its
project receipt binds exact bytes and normalization, including exact legacy
instruction-impact and agent, router, or skill surface-action mismatches. A
blocked retired `publication` mode may map only to current `feature` semantics
with exact terminal event and receipt hashes. It does not promote a blocked
unit's planned surface to complete or claim an edit, validation, acceptance,
execution, or publication; current portable registries and all current/future
instruction rules remain closed.

When immutable historical metadata prevents a complete aggregate while the
current feature still validates, use only the independently signed,
[historical validation-debt baseline](docs/HISTORICAL_VALIDATION_DEBT_BASELINE.md).
It ratchets one exact unresolved failure set and reports debt-bearing success;
it does not repair history or claim a clean workspace.

One exact current active feature unit may correct only its legacy
`architecture_decision` shape and wholly absent required
`rusty-morphospace`/`system-engineering` surface records through the
[active unit contract correction](docs/ACTIVE_UNIT_CONTRACT_CORRECTION.md).
It is a caller-pinned transactional repair, not a generic unit editor or an
instruction-completion, validation, acceptance, or publication route.

An immutable non-current/non-next in-flight unit pair may use the narrower
authenticated compatibility projection only for one exact owner Ready-to-
WithdrawReady history and one exact v2 supersession history. The closed receipt
projects only its named validation-profile and skill-action meanings while
leaving raw unit bytes unchanged and changing only the current state's event
tail. It does not claim instruction work, validation, completion, acceptance,
or publication. See [historical unit adoption](docs/HISTORICAL_UNIT_ADOPTION.md).
The projection remains valid after an exact owner-produced local closure only
when its instruction-completion, `BeginValidation`, deep-pass
`RecordValidation`, and `Accept` transactions chain without gaps to the live
terminal state. Those transactions, not the projection, establish completion,
validation, and acceptance.

For an immutable terminal blocked unit whose bytes wholly omit a currently
required skill surface, the same receipt may project only the exact missing
required skill IDs at canonical `<skills-root>/<skill-id>/SKILL.md` paths.
Those projected surfaces remain `planned`; exact terminal hashes are required,
and optional, extra, current, accepted, completed, or executed claims reject.
The same terminal-blocked contract can project only exact closure-derived
read-only leaves for invalid legacy directory rows, or retain external scope
rows solely as evidence of completed additions-only project transactions while
projecting planning-only validation semantics. Both forms require exact
terminal and supporting artifact hashes; neither grants source write, runtime,
Git, remote, or device authority.

Portable project, unit, repository, feature, receipt, and event identities use
lowercase alphanumeric/hyphen syntax and support 2 through 128 characters.
Authority-stage protocols may declare a wider identity domain explicitly.

This repository packages the agent instructions, setup notes, dependency
matrix, validation scripts, and local-skill templates needed to bring up a
new contributor environment without relying on one maintainer's machine paths.

## Scope

Included:

- workspace layout and repo-lane orientation;
- dependency matrix for Rust, Android, Quest APK, Makepad, Termux sidecar, and
  agent workflows;
- routing guidance for app-owned OpenXR, Meta Spatial SDK native bridges, and
  app-packaged OpenXR API layers;
- four portable local skill templates plus explicit installation of the
  canonical Meta Quest workflow skill from `meta-quest-agent-workflow`;
- repo-lane routing for both Rusty-owned media streams and the separately
  bounded Hostess Meta/MQDH Cinematic presentation provider;
- project-local composition, feature activation, module extraction, promotion,
  and autonomous-iteration contracts;
- exact source-composition locks, detached materializations, resource claims,
  and repeated same-headset APK-run isolation contracts;
- JSON schemas, public examples, validators, and a no-overwrite project
  scaffold for those contracts;
- setup examples that use placeholders such as `<workspace-root>`,
  `<android-sdk-root>`, `<quest-serial>`, and `<path-to.apk>`;
- public/private boundary rules for notes, logs, APKs, screenshots, package
  identities, generated artifacts, and live headset evidence.

Not included:

- SDKs, APKs, OpenXR loader binaries, signing keys, screenshots, logcat dumps,
  device serials, or local tool caches;
- private planning state or private app payload details;
- a promise that ADB, Termux, shell helpers, or Meta tooling can bypass Quest
  platform permissions.

## Fast Path

For project iteration, “fast” is an explicit authority profile, not a synonym
for shallow testing. Use `guard_profile: fast` for bounded product work across
its declared repositories and device stages, `labs` for product-authority or
composition policy changes, and `locked` for releases or workflow trust-root
changes. Select `risk_tier` independently.

APK build lane is a separate choice. Warm iteration may reuse stable,
project/lane-scoped compiler and packaging intermediates; Candidate/publication
freezes exact clean inputs and immutable outputs. Both retain and inspect the
exact APK. See [Quest APK Workflow](docs/QUEST_APK_WORKFLOW.md) and
[Project Isolation](docs/PROJECT_ISOLATION.md).

[Direct Work Packages](docs/DIRECT_WORK_PACKAGES.md) provide a lightweight
front door for ordinary work. A validated `fast` package may proceed directly;
`labs` (the guarded lane), `locked`, or an under-declared profile graduates to
the existing autonomous-unit workflow before mutation.

The guard-profile, execution-preflight, `ReturnToActive`, and active write-scope
amendment additions on this development line are unreleased candidate behavior.
They do not amend the published `0.6.0` contract until the repository's
external validation-authority and release process accepts an exact candidate.
Use [External Validation Approval Proposals](docs/EXTERNAL_VALIDATION_APPROVAL_PROPOSALS.md)
to derive sorted canonical Git-object review input for a protected change.
The proposal is deliberately non-authoritative and still requires a separate
trusted-base policy decision plus independent static and dynamic validation.

Repository CI runs feature-branch validation from pull-request events, keeps a
post-merge `main` readback, and cancels superseded runs within the same pull
request without cancelling `main` readback.
The required Quick jobs own shared coverage; the Windows Standard job executes
only the additional work-unit automation gate. During local iteration, use
focused checks; freeze and commit the candidate before its one risk-selected
handoff aggregate. A dirty aggregate is diagnostic and is not a prerequisite
for a matching clean receipt. For a local Standard handoff, run Quick once and
then run `scripts/Test-WorkUnitAutomation.ps1` as the delta. Do not follow Quick
with cumulative `Test-WorkEnvironment.ps1 -Tier Standard`, which replays the
Quick suite for compatibility.

1. Run `pwsh -NoProfile -File .\scripts\Test-PowerShellHost.ps1` and read
   [Setup Overview](docs/SETUP_OVERVIEW.md).
2. Fill a private copy of [local.paths.example.json](templates/local.paths.example.json).
3. Run the environment smoke test:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -ConfigPath .\local\local.paths.json `
  -Profile Core `
  -Strict
```

4. Read [Local Skill Bootstrap](docs/LOCAL_SKILL_BOOTSTRAP.md), set the exact
   clean canonical Meta workflow checkout, then plan, install, and verify the
   five skill routers:

```powershell
$MetaWorkflowRoot = "<workspace-root>\meta-quest-agent-workflow"

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot $MetaWorkflowRoot `
  -TargetRoot <codex-skills-root> `
  -Action Plan

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot $MetaWorkflowRoot `
  -TargetRoot <codex-skills-root> `
  -Action Install `
  -Execute

pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-LocalSkills.ps1 `
  -MetaQuestWorkflowRepoRoot $MetaWorkflowRoot `
  -TargetRoot <codex-skills-root> `
  -Action Verify
```

Plan and Verify report source-unowned files without deleting them. Use the
fingerprint-bound, backup-first `PruneUnmanaged` action only after reviewing one
skill's exact reported inventory.

5. For a new or existing application, read
   [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md), then run a
   protocol-v2 scaffold dry run (v1 remains readable for existing workspaces):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\New-ProjectWorkspace.ps1 `
  -ProjectRoot <project-root> `
  -ProjectId <project-id>
```

6. For Quest APK work, read [Quest APK Workflow](docs/QUEST_APK_WORKFLOW.md)
   and use the public Meta Quest workflow repo as the device-operations
   authority. Select warm iteration or Candidate/publication before building;
   do not turn content-addressed final outputs into per-edit cold compiler
   roots. Routine local work uses a complete hash-pinned File Manager provider
   closure (entry point plus declared runtime siblings), staged in a
   content-addressed run root and recorded without local paths; it does not use
   a lone copied executable. QFM runtime v5/global-focus v1 data and the
   separate read-only permission-observation v1 facts remain distinct; only
   an app-owned receipt can establish application or OpenXR readiness, and no
   QFM permission fact establishes policy or feature use. Kiosk
   launch/foreground control when applicable, and app-owned runtime evidence.
   For OpenXR inspection or interaction, explicitly choose an app-native route,
   a bridge over the existing Spatial SDK session, or a packaged API layer.

When a repository changes its own validation policy, workflow, schema, or
runner, use the two-step
[External Validation Authority](docs/EXTERNAL_VALIDATION_AUTHORITY.md)
also defines the pinned-owner signed-comment gate for the one exact protected
change lacking a base approval. It can authorize only a base static assessment,
never execution, acceptance, or publication.
boundary. A base-owned policy admits an exact reviewed change set without
checking out or executing candidate content; dynamic validation and
publication authority remain separate.
   Managed target-set work uses Fleet with current authority and effect-owner
   receipts. Local File Manager and managed Fleet contracts remain separate;
   raw ADB requires an explicit bootstrap, provider-gap, diagnostic, or
   recovery fallback.

For Quest-to-PC visuals, keep the Rusty-owned display/media stream and the
Hostess Meta/MQDH Cinematic route distinct. The former exposes owned media
plane evidence; the latter is an opaque supervised presentation provider whose
recording, input, Meta device-session cleanup, and FOV restoration claims stay
separate. Route the version-sensitive procedure through the canonical Meta
Quest workflow rather than copying it here.

The checked-in [Hello Morphospace V2](examples/hello-morphospace-v2/README.md)
workspace demonstrates an inert lock, a proposed bounded unit, and semantic
validation without a device.

## Project Iteration

- [Project Workspace Protocol](docs/PROJECT_WORKSPACE_PROTOCOL.md) defines the
  project-local control surface and agent resume order.
- [Module Lifecycle](docs/MODULE_LIFECYCLE.md) defines extraction and stable
  promotion, including the second-consumer gate.
- [Feature Activation](docs/FEATURE_ACTIVATION.md) makes absent features inert
  and requires one parameter authority plus a fingerprinted selected lock,
  explicit runtime input, and effective-runtime receipts.
- [Autonomous Iteration](docs/AUTONOMOUS_ITERATION.md) defines work-unit scope,
  compact state, event notes, validation tiers, larger push checkpoints, and
  the optional fail-closed work-unit automation CLI.
- [Workflow Stability And Feature Throughput](docs/WORKFLOW_STABILITY.md)
  defines validation-only review units, claim preflight, exact generated
  handoffs, semantic gates, one-captain ownership, and the three-feature-unit
  stability window.
- [Repository Lifecycle Advisory](docs/REPOSITORY_LIFECYCLE.md) defines the
  strict read-only ref/worktree hold registry, three-state disposition, exact
  tip readback, owner-release boundary, and separation between remote ref
  retirement and local cleanup.
- [Fast Local Worktree Index](docs/LOCAL_WORKTREE_INDEX.md) defines the Tier 0
  registration-only shortlist pass, zero-status/zero-network boundary, and
  escalation to exact-path and operational checks only when needed.
- [Canonical Text Bytes And Signing Preflight](docs/AUTONOMOUS_ITERATION.md#canonical-text-bytes-and-signing-preflight)
  defines explicit LF enrollment, byte-exact historical/binary preservation,
  cross-platform checkout parity, and the non-normalizing pre-signing check.
- [Active Read-Only Dependency Correction](docs/ACTIVE_READ_ONLY_DEPENDENCY_CORRECTION.md)
  defines the exact-CAS transaction for correcting only an active unit's
  project-declared parse/build dependency closure.
- [Active Project Repository Scope Correction](docs/ACTIVE_PROJECT_REPOSITORY_SCOPE_CORRECTION.md)
  defines the additive, unit-bounded transaction for a project allow-list path
  omitted during admission.
- [Event-Ledger Prefix Normalization](docs/EVENT_LEDGER_PREFIX_NORMALIZATION.md)
  defines the one-time typed correction for exactly one leading CRLF blank
  record while preserving strict ordinary parsing and every prior event byte.
- [Project, Build, And Headset Isolation](docs/PROJECT_ISOLATION.md) separates
  concurrent source/build identities while serializing transactional runs on
  one headset.
- [Rust Toolchain Policy](docs/RUST_TOOLCHAIN_POLICY.md) records the observed
  Rust 1.97.1 baseline, independent repository declarations, and the monthly
  advisory/quarterly pinned-refresh cadence without central enforcement.
- [Instruction Synchronization](docs/INSTRUCTION_SYNCHRONIZATION.md) keeps
  skills, planning instructions, touched-repo `AGENTS.md`, and README/router
  docs aligned without duplicating long recipes.
- [Affected Validation](docs/AFFECTED_VALIDATION.md) defines exact-tree
  current-delta selection, content-addressed evidence reuse, full-history Deep,
  and fail-closed infrastructure handling for CI.
- [History Archive Checkpoints](docs/HISTORY_ARCHIVE_CHECKPOINTS.md) defines
  additive raw-byte history checkpoints, bounded live tails, and the distinct
  Quick versus Deep/audit/migration replay routes.
- [Release Capsules And Historical Closure](docs/RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md)
  separates an exact candidate cut from later ancestry-based audit closure, so
  normal post-release commits and dirty local work do not rewrite a release.

This repository owns the portable protocol. The project adopting it owns its
live `morphospace/` state and evidence.

Receipt-security corrective units use a stricter hash-pinned runner and derived
v2 receipt. Preflight remains non-promotional. See
[Advanced Validation Authority](docs/VALIDATION_AUTHORITY_ADVANCED.md) before
changing that path or running its Deep tests.

New scaffolds use `project_spec.v2`, `feature_lock.v2`, and
`workspace_state.v2`. Exact feature descriptors resolve through
`scripts/Resolve-FeatureLock.ps1`; `scripts/Test-FeatureActivationAgainstLock.ps1`
provides the fail-closed selection/fingerprint/runtime-input gate. Existing v1
workspaces remain valid and migrate additively rather than being rewritten.
Resolver filesystem paths are local adapter inputs only: v2 locks retain
forward-slash descriptor references relative to `project.spec.json` and reject
absolute, parent-traversing, or out-of-project descriptor locations.
If a corrective unit supersedes an immutable historical active/validating
unit, append the exact
`<old-unit>-superseded-by-<current-unit>` state-transition event and keep the
replacement as the sole current unit; do not rewrite the old unit or event
prefix. The transactional ledger rejects the transition before intent
publication unless event `unit_id` independently identifies the old
active/validating unit, target-state `current_unit` and the target unit identify
the distinct replacement, and the event ID is their exact unambiguous
rendering. A supersession uses a v2 intent that hash-binds the original state
document and exact old-unit path/document. Completion rejects legacy or damaged
bindings before applied-target recovery, torn-tail repair, or projection writes.
If that exact replacement later reaches the owner-defined terminal
`validation-fail` route, aggregate validation admits its blocked status only
from the authenticated v2 supersession transaction and the complete directly
chained `BeginValidation`/fail transactions, including the same-unit fail
receipt, blocker/checkpoint, and exact historical state/unit targets. The proof
remains valid after later legitimate units advance only when every later owner
transaction derives the live projection. A later intent v3 or v4 is admitted
only as an exact non-supersession suffix transaction with one or two ordered canonical
project/lock projections: a first-seen path must be an unchanged anchor, a
later change must chain its prior target into the next preimage, and the last
target must equal the live document. Unknown properties, changed unanchored
paths, captain/status/readiness changes, status-only mutation, damaged history,
or acceptance inference remain invalid. V4 also binds the exact canonical unit
path and lowercase raw-byte SHA-256 through `pre_unit_raw`. Run
`scripts/Test-BlockedSupersessionTerminalValidation.ps1` for the neutral
owner-produced one-projection, two-projection, chained-advance, and adversarial
fixtures.
V3/v4 artifact validation resolves portability deterministically: it canonicalizes
and case-insensitively deduplicates every target path before any filesystem
lookup, then validates the unique artifacts and their exact receipt set.
One completed legacy-v1 fault has a separately reviewed append-only repair:
an otherwise exact `<old>-superseded-by-<replacement>` event that recorded the
replacement in `event.unit_id`. Use only the derived
`completed_transition_semantic_correction.v1` receipt and
`CorrectCompletedTransitionSemantics`; it preserves all historical bytes,
changes only `last_event_id`, and authorizes the old endpoint in contract
validation only after both historical and correction transaction chains are
authenticated. See [Completed-Transition Semantic Correction](docs/COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md).

The automation CLI inspects or plans by default. `-Execute` is required for a
workspace-state transition; it still does not run Git push, force-push,
checkout/reset/stash, validation commands, or live device commands.
Use `-Action Ready -Execute` to review a bounded `proposed` unit into the
claimable queue after its prerequisites are accepted; this replaces manual
status/state/event edits. If another unit is current, Ready uses the same
canonical supersession-ID constructor as execution and rejects an event ID
longer than 128 characters before mutation. Use `-Action WithdrawReady` only
for the exact `next_ready_unit`: it authenticates that unit's unique original
Ready transaction, changes only `ready` to `proposed`, deterministically
recomputes the queue, and installs its receipt with the withdrawal event.
Withdrawn identities cannot be readied again; a revised proposal uses a new
unit identity.
Use `-Action RecordHistoricalUnitCompatibilityProjection` only with a
builder-produced, reviewed SHA-bound closed receipt for the exact historical
pair. The action is dry-run by default and atomically installs the receipt plus
one tail-only state event; it never edits either historical unit.
Run `Inspect` with the exact repository map before Claim. Its embedded
`claim_preflight` resolves writable repositories, read-only input paths,
instruction aliases/files, resource declarations, validation tier, and device
selection. Ready and Claim use the same instruction-action result. A feature
unit may retain only the closed lifecycle-routed external skill reviews; its
repository-owned instruction surfaces remain updates, and the local map must
register the canonical `<skills-root>` surface separately from writable source
authority. Claim does not change state unless the preflight passes.
The preflight also reports whether the unit's explicit `fast`, `labs`, or
`locked` guard is sufficient. Immutable older units remain readable through
risk-tier inference, while new units declare the guard.
When a unit declares `execution_preflight`, Claim also verifies a hash-pinned
observation of exact identity values and capabilities before an expensive build
or device stage. The runner reads that evidence; it does not generate it or
execute the expensive path.
Use `scripts/New-WorkUnitHandoff.ps1` to bind exact unit/state/event/repository
hashes and copy validation and acceptance commands verbatim for the next
captain or execution stage.
For a matching active or validating unit with declared instruction surfaces, use the two-phase
`CompleteInstructionSurfaces` action before validation. Its dry run reports
the exact unit hash, stable instruction-file observation hash, and complete
planned-surface ID set. Execution must replay those values and installs the
receipt transactionally; it does not execute the surfaces' validation
commands or amend any other unit field.
Use `NormalizeEventLedgerPrefix` only for the exact protocol-v2 framing defect
defined by its runbook. It requires a clean worktree plus caller-bound
repository, project, state, unit, event-ledger, tail, and dry-run intent
identities; it appends one correction event, publishes the normalized receipt
only after exact target readback, and changes no state field except
`last_event_id`.
Use `CorrectActiveReadOnlyDependencies` only for an exact current `active` unit
whose existing build or workspace parser needs corrected read-only identities.
Its correction binds the full before/after dependency sets, state/unit/event
CAS, and one full commit/tree per resulting dependency. It can add only
project-declared, non-writable paths and changes no other unit field. See
[Active Read-Only Dependency Correction](docs/ACTIVE_READ_ONLY_DEPENDENCY_CORRECTION.md).
Use `CorrectActiveProjectRepositoryScope` only when an exact current `active`
unit already declares a writable path that its project repository allow-list
omits. The action is additive-only, preserves the unit, and atomically advances
the project revision, feature lock, and workspace registry through transition
intent v3. See [Active Project Repository Scope Correction](docs/ACTIVE_PROJECT_REPOSITORY_SCOPE_CORRECTION.md).
When implementation discovers another writable path or repository that is
already inside the project allow-list and the same feature authority, use the
two-phase `AmendActiveWriteScope` action. It adds scope only to the current
active feature unit, retains its captain and status, and mutex-binds the
unchanged project spec. It never edits project authority or performs source,
Git, build, validation, device, or remote work. See
[Active Write-Scope Amendment](docs/ACTIVE_WRITE_SCOPE_AMENDMENT.md).

For an idle existing project, first use the bounded owner
[development-envelope preparation](docs/DEVELOPMENT_ENVELOPE_PREPARATION.md)
contract, then start the next feature through the bound
[development-unit admission and candidate-freeze contract](docs/DEVELOPMENT_UNIT_ADMISSION.md).
It supports agent-led discovery inside a declared envelope, then freezes exact
candidate identity before normal validation.
When a ready unit carries sealed evidence from an out-of-scope prior task,
`Claim` binds it as historical evidence only. The owner must then materialize
and verify a task-local reference before source work; the raw patch is never
applied or made a product input. See [Inherited Candidate
Materialization](docs/INHERITED_CANDIDATE_MATERIALIZATION.md).
`CorrectCompletedTransitionSemantics` is not a compatibility mode for malformed
events. Its builder derives the old and replacement from current retained
state/unit evidence, requires the original event receipts and legacy-v1 intent
artifacts to be empty, and installs the inspected receipt as the correction
transition's sole artifact.
`RecordValidation` and `Accept` require a local `validation_receipt.v1` whose
hashed artifacts, exact acceptance/gate coverage, repository revisions,
changed paths, and required device cleanup/fatal fields still match current
state.
For a non-passing feature attempt that remains in scope, `ReturnToActive`
retains the same receipt and returns `validating` to `active` without releasing
the captain or creating a blocker. Non-passing `RecordValidation` remains the
stop-and-release path.
One exact active-unit blocker may be cleared through the additive,
product-neutral `ResolveBlocker` route. Its strict receipt binds the blocker,
passing evidence, current attached-branch or exact detached repository heads,
exact per-repository dirty source bytes, and every other blocker that must
remain unchanged. Replay checks inspect direct workflow receipts and their
bound event references without treating nested product evidence as resolution
receipts. See
[Generic Blocker Resolution](docs/BLOCKER_RESOLUTION.md).
When that immutable resolution remains historically valid but its broader
complete-resolution evidence was incomplete, use the separate append-only
`CorrectResolvedBlockerEvidence` route. It binds the original
event/receipt/intent/completion chain plus fresh exact repository source
evidence and changes only `last_event_id`. See
[Blocker Resolution Correction](docs/BLOCKER_RESOLUTION_CORRECTION.md).
For the distinct legacy terminal-newline fault where an immutable
blocker-resolution receipt and intent were retained with CRLF while their
transaction recorded LF bytes, use only the cross-unit additive
`CorrectHistoricalBlockerResolutionIntentBinding` route. It binds the exact
current active-unit CAS, both historical raw-byte pairs, and every unaffected
transaction field; it changes only `last_event_id`. See
[Historical Blocker-Resolution Intent-Binding Correction](docs/HISTORICAL_BLOCKER_RESOLUTION_INTENT_BINDING_CORRECTION.md).
Interrupted cross-repo commits, builds, and device runs resume only from a
validated `interruption_receipt.v1`; the automation restores workflow state
after cleanup evidence exists but never performs the external cleanup.
Work already in flight before protocol v2 can cross the normal dirty-claim
gate only through a generated `inflight_adoption_receipt.v1` that exactly
hashes every dirty in-scope file or deletion and becomes stale on any change.
Prepared push plans use `execution: not-performed`. After an authorized
external push, `executed_push_receipt.v1` records exact old/new/readback refs,
ancestry, hash-bound validation files, a pre-publication capture when required,
planning-final-suffix order, no-force proof, and rollback points;
validate it with `scripts/Test-ExecutedPushReceipt.ps1`.
Use `scripts/Invoke-ProtectedBranchPushGuard.ps1` when a local pre-push hook
must canonicalize an explicit source selector such as `HEAD`; it binds the
destination to the exact attached protected branch before plan validation.

After a prepared push is externally executed, use
`planned_publication_accounting.v1` and the fail-closed `RecordPublication`
action to enumerate every published commit, preserve carried blocked-unit
status without claiming acceptance, validate the single planning-transport
suffix, and consume only the exact pending bundle. Prepared evidence may bind
standalone plan/event files or their immutable automation-receipt and
transition-ledger containers. See
[`docs/PLANNED_PUBLICATION_ACCOUNTING.md`](docs/PLANNED_PUBLICATION_ACCOUNTING.md).
A normal source integration may use `changed_paths: []` only on an explicitly
typed exact two-parent merge whose preceding side/content commit remains
separately enumerated with full triggering-unit attribution. Parent order,
trees, merge base, four complete path projections, and the empty plain merge
projection are verified live; every linear or untyped merge entry remains
nonempty.
For the separately owner-authorized normal linear shape in which a planning
receipt-only commit is already clean and only the five transaction-owned
`PreparePush` paths remain dirty, use the exact-bundle
[`prepared_push_transaction_suffix_reconciliation.v1`](docs/PREPARED_PUSH_TRANSACTION_SUFFIX_RECONCILIATION.md)
route. It verifies the signed scope and consumes only the matching pending
bundle without changing Git, evidence bytes, timestamps, acceptance, or
publication authority.
If immutable execution predates its recorded preparation timestamp, typed merge
topology cannot repair that chronology and normal accounting must still reject.
The distinct
[`executed_prepared_publication_reconciliation.v1`](docs/EXECUTED_PREPARED_PUBLICATION_RECONCILIATION.md)
route preserves every timestamp and parent, verifies complete path-set
fingerprints and live refs, and consumes only the exact bundle without claiming
corrected chronology, flattened history, Git mutation, or ordinary accounting.
The additive post-0.6.0
[prepared-push retirement candidate](docs/PREPARED_PUSH_RETIREMENT.md) handles
only an exact pending bundle whose immutable plan records
`execution: not-performed`. It requires complete stable clean repository and
fresh remote-readback evidence, rejects execution/publication bindings and
remotely reachable prepared ahead revisions, and retains a hash-bound receipt.
Current `PreparePush` writes that plan only as the preparation transition's
single byte-exact owned artifact; retirement rejects a plan path, hash, or
payload that differs from the historical intent.
It is not a published 0.6.1 release and does not reinterpret publication or
reconciliation.
When every distinct prepared revision is reachable while the immutable plan
still says `not-performed`, use
[prepared-publication reconstruction](docs/PREPARED_PUBLICATION_RECONSTRUCTION.md).
It enumerates exact intervening history and clears stale bookkeeping without
claiming execution, chronology, force history, actor/time, or historical
non-publication.
An immutable executed bundle followed by a separately accepted workflow
correction uses the additive intervening-publication recovery, which binds the
exact fast-forward commits and paths through current clean remote readback. It
preserves the original readback-only nonclaim and is never general drift
tolerance.
Its live prerequisite may contain only the new accounting receipt when the
unchanged executed receipt path/hash is already proven exactly once in the
enumerated intervening planning history; ordinary accounting remains two-path.
A no-force prerequisite suffix that was already published before
`RecordPublication` uses the separate
`published_prerequisite_suffix_reconciliation.v1` evidence contract and
`ReconcilePublishedPrerequisiteSuffix` action. That route accepts only one
planning commit containing exactly the bound executed-push and accounting
receipt paths, with unchanged source refs; it does not broaden ordinary
accounting or tolerate rewrites.
The additive v2 form accepts only an exact two-commit linear suffix when the
second commit corrects the accounting receipt and both commits remain confined
to those same two receipt paths; all identities are full 40-hex revisions.
A later force-with-lease replacement of a published planning-only finalization
suffix uses the cardinality-bounded additive incident recovery documented in
[`PLANNED_PUBLICATION_ACCOUNTING.md`](docs/PLANNED_PUBLICATION_ACCOUNTING.md);
it preserves the earlier no-force execution and rejects any source rewrite.

Push preparation now requires one distinct external planning repository that
contains the active project workspace. The source refs remain first and that
planning ref is the final prepared suffix. If a source push already occurred
without `PreparePush`, preserve the real publication and use the additive
`unplanned_publication_closure.v1` plus `ReconcilePublication`; never create a
retrospective plan or relabel the reconstruction as an executed-push receipt.
If the project workspace was embedded in that source, first project its exact
published-tree bytes to distinct external planning. Use
`planning_workspace_projection.v1` and `unplanned_publication_closure.v2` only
when an actual pending bundle remains. If current, next-ready, and pending
bundle are null while the embedded state still carries the source dirty marker
and a stale projected head, use `planning_workspace_projection.v2` and the
workflow-only `AdoptPublishedPlanningAuthority` transition instead. See
[External Planning Projection And Historical Reconstruction](docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md).
If planning alone published early while every source remote remains unchanged,
use the hash-bound publication-ordering interruption input to create a fresh
plan that preserves the fault and claims no publication or corrected order.

The additive unreleased
[unpublished planning-authority materialization](docs/UNPUBLISHED_PLANNING_AUTHORITY_MATERIALIZATION.md)
handles a different case: exact project workspace bytes exist only in one
intentionally dirty source checkout and no published-tree projection applies.
It accepts only repository-root `morphospace/` plus the exact
`workspace.state.json` anchor, proves live bytes differ from the pinned source
tree, and copies only the complete bounded inventory into a distinct clean
planning repository. It installs a canonical, tool-generated authority receipt atomically,
and leaves the source untouched. It is not a 0.6.0 release claim, workflow
admission, validation, acceptance, Git action, or projection v1-v3 variant.
Windows execution additionally binds and replays volume-serial plus 128-bit
FileIdInfo directory identities so `subst` and equivalent namespace aliases
cannot manufacture distinct source/planning authority.

Seal coordinated releases with `release_capsule.v1`. At publication,
`Test-ReleaseCapsule.ps1 -Mode CandidateCut` requires every declared remote ref
to equal the pinned commit. Later, `-Mode HistoricalClosure` requires the
pinned commit to remain an ancestor-or-equal while verifying the exact clean
tree in isolation. The validator observes active worktrees but never mutates
them or treats their overlays as release payload.

The first downstream adoption proof lives in Rusty Quest's public
`apps/spatial-camera-panel-android/morphospace/` directory. It demonstrates a
behavior-neutral bootstrap: one selected base shell, explicit disabled optional
families, one absent/inert nearby feature, candidate records, a compact next
unit, and a project-owned static gate.

## Repository Layout

```text
AGENTS.md
README.md
docs/
examples/
manifests/
schemas/
scripts/
skills/
templates/
```

The repo is designed to be cloned beside source repositories, for example:

```text
<workspace-root>/
  rusty-morphospace-work-environment/
  repos/
    Rusty-XR/
    Rusty-XR-Companion-Apps/
    rusty-manifold/
    rusty-manifold-packages/
    rusty-matter/
    rusty-optics/
    rusty-lattice/
    rusty-lsl/
    rusty-gui/
    rusty-quest/
    rusty-hostess/
    rusty-quest-sidecar-mesh/
    makepad-morphospace/
```

The exact layout is not mandatory. Store local paths in ignored files under
`local/` or in your shell profile, not in committed docs.

## Public Upstreams

- Rusty Morphospace Work Environment: `https://github.com/MesmerPrism/rusty-morphospace-work-environment`
- Rusty XR public core: `https://github.com/MesmerPrism/Rusty-XR`
- Rusty LSL: `https://github.com/MesmerPrism/rusty-lsl`
- Meta Quest agent workflow: `https://github.com/MesmerPrism/meta-quest-agent-workflow`
- Quest Termux Lab: `https://github.com/MesmerPrism/quest-termux-lab`
- Rusty Quest sidecar mesh: `https://github.com/MesmerPrism/rusty-quest-sidecar-mesh`

These repositories remain their own sources of truth. This workspace repo
collects the onboarding path across them.

## License

AGPL-3.0-or-later. See `LICENSE`.

Planned publication accounting can fail closed over an immutable executed
range containing multiple separately accepted units while retaining its one
prepared trigger. See `docs/PLANNED_PUBLICATION_ACCOUNTING.md`.
