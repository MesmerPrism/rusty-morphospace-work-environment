# Agent Notes

Production declaration vocabulary is accepted only through the versioned
`change_category_aliases` mapping in the lifecycle manifest. Aliases must map
one-to-one to existing canonical categories and inherit their instruction and
skill routing; they never relabel accepted historical evidence.

Publication accounting may represent an unchanged declared repository only
through exact synchronized readback: equal revisions, executed
`readback-only`, clean state, zero commits, bound identity/order/status, and an
explicit no-acceptance claim. Never use it for a changed repository.
An already executed synchronized-readback bundle may advance only through the
additive intervening-accepted-publication recovery: exact execution-time and
current revisions, fast-forward commits/paths, accepted/pass evidence, narrow
planning evidence roles, clean no-force readback, and source-first/planning-
last chronology. This is not general remote-drift tolerance.
Only that recovered shape may use an accounting-only local prerequisite suffix,
and only when exact bound executed evidence is already present once in its
enumerated intervening planning history. Normal accounting still requires both
prerequisite evidence paths.

An embedded same-source workflow may move after publication only through an
exact planning-workspace projection into one distinct external planning
repository. Use `planning_workspace_projection.v1` plus
`ReconcilePublication` only when a real pending bundle still exists and the
unplanned-publication closure can consume it without reconstructing a plan.
Use `planning_workspace_projection.v2` plus
`AdoptPublishedPlanningAuthority` when current, next-ready, and pending-bundle
state are all null but the published embedded state still marks the source
dirty and projects a stale source head. The v2 transition binds the exact stale
head and state hash, clears only that source dirty marker, updates only that
repository-head entry to clean synchronized readback, preserves every unrelated
state field, and performs no Git operation. A drifted historical-unit adoption
reference remains damaged; admit a separate independently anchored
reconstruction only through
`historical_unit_adoption_reconstruction.v1` and current-validation projection.
Use `planning_workspace_projection.v3` plus a
`published_planning_authority_adoption.v2` receipt when the exact published
embedded workspace still has the matching active or validating unit but no
next-ready unit or pending bundle. That migration preserves the unit, dirty
set, repository projections, and every state field except the deterministic
adoption event ID. It creates no validation or acceptance evidence; finish the
unit through ordinary external-workspace transitions.
See `docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md`.

When exact project workspace bytes exist only in one intentionally dirty source
checkout and no published-tree projection applies, use the additive unreleased
`MaterializeUnpublishedPlanningAuthority` contract. It accepts only the exact
repository-root `morphospace/` directory and `workspace.state.json` anchor,
derives dirt and pinned-tree divergence rather than accepting eligibility
prose, inventories and re-observes those bounded control bytes, atomically
installs it below one distinct clean planning repository, preserves the source
copy as historical/non-authoritative, and performs no Git or workflow
transition. Route the complete procedure to
`docs/UNPUBLISHED_PLANNING_AUTHORITY_MATERIALIZATION.md`; never use it to copy
sibling source/runtime files or replace `planning_workspace_projection.v1-v3`.
On Windows, require volume-serial plus FileIdInfo directory identities for both
repository/common-dir authorities and replay destination/stage identities;
lexical paths or namespace aliases alone never establish separation.

This repository is intended to be public and portable. Keep committed content
free of local machine paths, private repository names, device serials, package
identities, generated APKs, screenshots, logs, pairing material, signing keys,
and private app payload details.

## Required Routing

Use the local skill templates in `skills/` after installation:

- `rusty-morphospace`: public architecture, ownership, project workflow,
  boundary, validation, and agent routing.
- `rusty-morphospace-context`: explicit machine-local work-environment
  resolution before handing portable guidance to `rusty-morphospace`.
- `system-engineering`: authority, interface, observability, validation, and
  mitigation-map structure.
- `rust-work-graph`: inventory, source-root maps, and graph snapshots before
  broad refactors.
- `meta-quest-workflow`: the canonical external skill from
  `meta-quest-agent-workflow` for live Quest, ADB, APK install/launch,
  screenshot, logcat, Perfetto, Wi-Fi ADB, or Meta tooling operations.

Install and verify them through `docs/LOCAL_SKILL_BOOTSTRAP.md` and
`scripts/Install-LocalSkills.ps1`. Managed writes require `-Execute`; updates
create a backup and must not delete unmanaged local files. Plan and Verify
report unmanaged files without failing current managed content. Remove such
files only through the separately reviewed, fingerprint-bound, backup-first
`PruneUnmanaged -Execute` action.

This repository tracks four local routers. It installs
`meta-quest-workflow` only from an explicit clean canonical
`meta-quest-agent-workflow` checkout, records that repository and commit as the
skill source, and generates Work Environment locator metadata separately. Do
not restore a competing tracked copy under `skills/`.

Use PowerShell `7.6` LTS or newer through the `pwsh` executable for every
authoritative workflow, child runner, validation command, and documented
example. Windows PowerShell 5.1 is bootstrap detection only; do not add new
`powershell.exe`, `& powershell`, or `shell: powershell` execution paths.

For live headset work, prefer the public `meta-quest-agent-workflow` repository
as the device-operation source of truth. This repo may point to that workflow,
but it should not fork a competing Quest procedure.

For an active, explicitly scoped task, inspection and a progress report are
nonterminal: continue with the next already-authorized read-only or bounded
version-control-recoverable action. Own only locally launched children to a
terminal result. For hosted runs, use the single canonical owner binding and
bounded `pending-infra` handoff in `docs/AUTONOMOUS_ITERATION.md`; queued or
zero-job observation is never a pass, failure, rerun, or historical-validation
substitute. Re-prompt only for a real scope, authority, safety, or evidence
boundary.

## Public Boundary

Use placeholders in public docs:

- `<workspace-root>`
- `<repo-root>`
- `<android-sdk-root>`
- `<android-ndk-root>`
- `<jdk-root>`
- `<openxr-loader-so>`
- `<quest-serial>`
- `<package>`
- `<activity>`
- `<path-to.apk>`
- `<out-dir>`

Do not commit private evidence or local setup output. Keep those under ignored
`local/` or `artifacts/` folders.

## Project Workflow

For project composition, module extraction, explicit activation, or autonomous
iteration, read in this order:

1. `docs/PROJECT_WORKSPACE_PROTOCOL.md`
2. `docs/MODULE_LIFECYCLE.md`
3. `docs/FEATURE_ACTIVATION.md`
4. `docs/AUTONOMOUS_ITERATION.md`
5. `docs/PROJECT_ISOLATION.md`
6. `docs/INSTRUCTION_SYNCHRONIZATION.md`

For broad local validation, run
`Test-WorkEnvironment.ps1 -SelfTest -Tier Quick` once, then invoke
`Test-WorkUnitAutomation.ps1` only when the Standard delta is required. The
cumulative `-Tier Standard` form remains a compatibility aggregate for callers
that have not already run Quick; do not run it after a Quick checkpoint.
Use Deep only when the risk warrants it. A single failed child check fails the
selected aggregate. These tiers never authorize device work.
Repository CI executes candidate Quick and Standard-delta jobs only for pull
requests, retains the same matrix as post-merge `main` readback, and cancels
superseded runs within the same pull request without cancelling `main`
readback. The required Quick jobs own the shared Quick coverage;
`standard-windows` runs only `Test-WorkUnitAutomation.ps1`.
Use focused checks on dirty source, then freeze and commit the candidate before
one risk-selected handoff aggregate. Do not require matching dirty and clean
aggregate receipts; a dirty aggregate is explicit diagnostic evidence.

Select change authority separately: `guard_profile: fast` for bounded product
iteration across its declared repositories and device stages, `labs` for
product-authority/composition policy work, and `locked` for releases or
workflow trust-root changes. `risk_tier` controls
evidence depth, not authority. For an in-scope feature failure, use the typed
`ReturnToActive` receipt path to keep the same captain; reserve blocker plus
`Resume` for a real stop or authority release.
`push_checkpoint: manual-owner-review` is only a publication hold: it requires
an explicit owner review before any publication step and grants no push, PR,
merge, release, validation, acceptance, or guard authority.

For expensive package, signer, grant, toolchain, or bridge-dependent work,
declare a hash-bound `execution_preflight_observation.v1` and exact assertions
before Claim. The workflow reads this non-sensitive observation but never runs
its producer, a build, a device command, or a bridge.

Before Claim or an expensive final matrix, route the exact real consumer
inventory through the advisory `Inspect` preflight and follow the candidate-
freeze and control-plane budget in `docs/AUTONOMOUS_ITERATION.md`. Its
`pass`/`fail`/`incomplete` result is diagnostic only; it does not replace
`ready_to_claim`, mutate workflow state, or authorize Claim.

For the closed explicit-feature instruction compatibility, Ready, Inspect, and
Claim must use the same bound repository-map preflight. Repository-owned
required instruction surfaces use `update`. Only the exact lifecycle-routed
`rusty-morphospace` and `system-engineering` installed surfaces may remain
`review-no-change`, and only when the map registers their canonical
`<skills-root>` root as the distinct external `skill-surfaces` source. A
path-shaped or writable lookalike is not external authority.

The work-environment repo owns portable schemas, examples, and validators. A
project owns its instantiated `morphospace/` directory. Do not copy live state,
private evidence, or machine paths back into this repository.

Immutable accepted or blocked units may retain legacy workflow vocabulary only
through a project-owned hash-bound historical-unit adoption receipt. Current
and future units remain strict. A blocked retired `publication` unit may map
only to `feature` with exact terminal event and receipt hashes. Exact legacy
instruction-impact and agent,
README/router, or skill surface-action mismatches use the same complete,
path-bound adoption contract; a blocked unit's planned status remains planned
and never claims an edit or validation ran. This is not an instruction-sync
exemption or publication evidence. Route the complete contract to
`docs/HISTORICAL_UNIT_ADOPTION.md`; never rewrite historical unit or event bytes.
If a required skill surface is wholly absent from immutable terminal blocked
unit bytes, project only the exact currently required skill IDs and canonical
`<skills-root>/<skill-id>/SKILL.md` paths. Retain `planned`, bind the terminal
event and receipt hashes, and reject current, accepted, optional, or extra
surfaces; the projection never claims an instruction edit or completion.
If an exact accepted unit wholly omits a skill route introduced after its
acceptance, use `later_required_skill_surfaces` to bind every and only the
current missing skill IDs, canonical paths, accepted event lines, and passing
validation receipts. Record `not-required-at-acceptance`; never synthesize a
surface or completion. A raw active/validating historical unit gets no adoption
receipt: defer only its evolving instruction-policy failures, and discharge
them only after the same aggregate pass authenticates its exact canonical
supersession event. Structural, registry, event, and current-unit checks remain
immediate.
For one non-current/non-next in-flight historical pair whose immutable bytes
cannot use terminal adoption, use only the project-owned
`historical_unit_compatibility_projection.v1` and
`RecordHistoricalUnitCompatibilityProjection`. It authenticates the exact
Ready-to-WithdrawReady and v2 supersession transactions, projects only its
closed profile/action mappings, preserves the raw units and current authority,
and changes only the compact-state event tail. It never records an instruction
edit, completion, validation, acceptance, or publication authority.
If that authority later closes locally, authenticate only its exact owner-
produced instruction-completion, `BeginValidation`, deep passing
`RecordValidation`, and `Accept` transaction suffix. The receipt may preserve
the raw `review-no-change` skill actions while projecting their current
`update` compatibility; only those owner transactions establish completion,
validation, or acceptance.
An exact supersession replacement may remain honestly `blocked` after typed
validation failure only when aggregate validation authenticates its historical
v2 supersession intent/completion and its immediately chained
`BeginValidation` and `validation-fail` intents, completions, events, same-unit
fail receipt, blocker/checkpoint, and terminal blocked/current-null projection.
Every later ledger event must extend those owner transaction preimages and
derive the live state and touched unit bytes. A later v2 transaction is valid
only as the exact owner-produced old-to-ready-replacement supersession. A later
v3 or v4 projection transaction is valid only with its exact owner property
set, one or two canonical ordered
`feature.lock.json`/`project.spec.json` projections, unchanged first-seen
anchors, prior-target-to-next-preimage chaining for a changed anchored path,
and final live projection derivation. It may not carry a supersession, change
captain/status/readiness/acceptance state, or tolerate unknown fields;
later legitimate units may proceed, but a status-only blocked replacement,
damaged chain, detached continuation, or inferred acceptance fails closed.
V4 additionally requires the exact `pre_unit_raw` property set, canonical unit
path equality, and lowercase raw SHA-256 binding. For v3/v4 artifacts,
canonicalize and case-insensitively deduplicate the complete
target-path set before any live lookup, then validate each unique payload,
hash, live byte sequence, and event-receipt binding.
For a terminal blocked validation unit, map an invalid legacy read-only
directory only to every exact closure-derived current project leaf. A completed
planning scope precursor may retain external rows only as hash-bound evidence
of its additions-only correction transactions while projecting
`validation-only`, `[validation]`, and its original `morphospace/` write scope.
Reject broader, optional, renamed, colliding, evidence-drifted, current, or
write-authorizing projections; removing the receipt must restore strict
validation.

Portable composition and iteration IDs have one 2-through-128-character
lowercase alphanumeric/hyphen domain across their schemas and validators.
Changes to that domain require passing boundary coverage at 64, 65, 128, and
129 characters. Separately versioned authority-stage IDs may declare wider
bounds explicitly.

### Staged validation-authority boundary

The ownership, registry, trust migration, closed-room validation-v2, and
transactional state/event layers form a staged corrective authority path. A
receipt-security record attempt must pass the quick workspace contract, select
a hash-pinned runner release, seal an exact content-addressed input capsule,
probe the child host, and publish a same-input typed validator-admission result
before the nonce-bound authority runner can record evidence. The admission
probe verifies the sealed validator, unit contract, command identities, and
acceptance bindings without executing acceptance commands. Preflight is
fail-fast admission only and does not prove validation, acceptance, device
behavior, or an external operation.

Keep Git ownership observation bounded by aggregate tree/index/diff calls plus
leased worktree bytes and repeated aggregate boundaries; never scale protected
Git subprocess count per dirty path.

Every authority stage preserves a typed, bounded result and input identities
before cleanup. Reuse a clean-room cache only after the capsule, runner,
materialization, host, and fresh fingerprint checks match exactly; partial,
tampered, stale, or mismatched caches reject and clean up only their owned
temporary paths. Ordinary application work remains in a separate project-local
`morphospace/` workspace with exact path scope and inert default locks. Never
present recovery-source tests as acceptance of the central corrective unit.
Keep canonical authority documents schema-pure: path/location metadata belongs
in runner variables or typed reference wrappers, never injected properties.

When a pull request changes the policy or runner that would validate that same
change, use the separate base-owned external validation-authority boundary in
`docs/EXTERNAL_VALIDATION_AUTHORITY.md`. Static admission reads policy from the
exact trusted base tree and inspects fetched candidate Git objects without
checking them out or executing them. It never attests execution or authorizes
publication. Keep ordinary application changes on their proportional
single-PR path.
Only the exact protected-without-base-approval v1 result may enter the durable
external owner gate. Require exactly one fresh pinned-owner authorization for
the current evidence, bound by RSA-PSS-SHA256 to complete
PR/Git/artifact/assessment evidence. Older mismatched comments remain inert
audit history. It permits only the base static assessment, never execution,
acceptance, merge, or publication; signing helpers print text only. Its unique
ID is audit identity, not mutable replay state: exact-candidate reruns are
idempotent within freshness, changed evidence rejects, and trusted-base
ancestry consumes the authorization.

## Authority Rules

- Rusty Morphospace names the ecosystem; concrete authority stays in lanes
  such as Matter, Lattice, Manifold, Optics, GUI, Makepad, Quest, Hostess, and
  app shells.
- Core crates start contract-first and dependency-light.
- Android package identity, signing, manifest permissions, OpenXR lifecycle,
  renderer ownership, headset install/launch, and visual validation belong to
  app shells or Quest workflow, not generic core crates.
- Distinguish app-owned OpenXR, co-resident bridges over engine-owned handles,
  and loader API layers. Quest owns layer packaging, activation, interception,
  and effective readback; the app owns semantic actions, while Manifold retains
  accepted-command, lease, replay, and revocation authority.
- Termux is a normal Android sidecar. It can use an already authorized ADB
  endpoint, but it is not shell authority by itself.
- Accessibility may provide a privacy-minimized top-level window-transition
  signal for an attended foreground watchdog. It does not own HOME, intercept
  the physical Meta button, or provide kiosk/device-owner authority; keep the
  detailed and version-sensitive recipe in `meta-quest-agent-workflow`.
- Android properties, JSON profiles, and hotload files are low-rate control
  surfaces. Do not route high-rate camera frames, meshes, particles, depth
  maps, or GPU buffers through them.
- Feature activation is closed-world: absent or unlisted means inert.
- Every mutable parameter has one authority owner; other entrypoints are
  adapters into that owner.
- A reusable module cannot become stable without an independent consumer or a
  neutral conformance harness plus an accepted promotion review.
- Direct networking keeps topology, platform network observation, socket
  ownership, exchange, and cleanup as separate authority surfaces; harnesses
  do not become product dependencies.
- Authenticated rendezvous is evidence only. Peer-session acceptance,
  revision, replay, expiry, peer change, and revocation belong to Manifold;
  product topology requires a fresh current-revision authorization bound to
  exact peer roles and topology contract before platform mutation.
- N-peer membership, coordinator epoch, route ranking, split-brain rejection,
  expiry, revocation, and audit remain Manifold authority. Public-lab and
  sidecar inputs are advisory only; only independently authenticated pairwise
  evidence may produce a direct-lane candidate, and gossip never carries media.
- Generic media composition keeps accepted Manifold session/stream references
  separate from platform lifecycle. Sources, processors, routes, codec/socket
  providers, and sinks stay explicit; compatibility adapters cannot export
  application defaults or permissions into reusable modules.
- Keep Rusty-owned media streams distinct from opaque operator-presentation
  providers. Hostess may supervise a separately installed Meta/MQDH Cinematic
  Cast process and report only its own observations; that does not make the
  route a generic Quest or Manifold media source or prove recording, input,
  device-session cleanup, or FOV restoration.
- Multi-app broker SDKs share only accepted contract families and the minimum
  platform permission. Every app keeps a distinct OS/package identity, client
  id, exact feature lock, marker namespace, grant, and app-local capability;
  pair-level validation must reject ambient unions and cross-app defaults,
  properties, markers, or authority-reset behavior.
- At most one iteration unit is active or validating in a project workspace.
  An immutable historical in-flight unit may be excluded from the current
  projection only by an additive
  `<old-unit>-superseded-by-<current-unit>` state-transition event whose
  replacement is the sole current unit; never rewrite the historical unit or
  event prefix to make the workspace look clean. Before publishing a
  transition intent, the generic ledger must derive the exact event ID from
  independently bound event-target old unit and target-state current unit,
  reject reserved-delimiter ambiguity, and publish a v2 intent binding the
  exact pre-state plus the active/validating old-unit path and document by
  canonical hashes. Legacy supersession intents fail closed; completion
  authenticates the binding before applied-target recovery or torn-tail repair.
- Cross-repository implementation and module extraction use an exact source
  composition lock; use detached clean materializations when working copies
  are changing in parallel. Observed, claimed, validated, and accepted
  revisions are separate state.
- Parallel APK builds require distinct package/client identities, stable short
  project/lane-scoped mutable intermediates, immutable content-addressed
  outputs, explicit native/shell/package invalidation, and complete run
  capsules. Warm iteration and clean Candidate/publication are separate build
  lanes. Runs on one headset are serial-scoped transactions that restore exact
  prior properties and stop only the target package.
- Machine-local resource claims coordinate repo paths, build outputs, Android
  packages, property/staging namespaces, bridge ports, and headset serials.
  Claims do not activate features or authorize Git/device operations.
- Repeatable Quest utilities prefer an owning application's closed typed
  CLI/local API when it can produce exact-target effective readback. Routine
  local work uses File Manager inspected deployment, Kiosk launch/foreground
  control when applicable, and app-owned runtime evidence. Managed target-set
  work uses Fleet with current authority and effect-owner receipts. Local File
  Manager and managed Fleet execution use disjoint contracts; raw
  serial-scoped ADB requires a labeled bootstrap, provider-gap, diagnostic, or
  recovery gate.
- A portable workflow intent contains no machine resolver, target, approval,
  coordination, credential, or Manifold state. Preserve owner evidence
  byte-for-byte and bind only its schema and SHA-256 from a sanitized wrapper.
  Add MCP only after the owning typed registry is stable; never expose a raw
  shell or generic ADB-argument surface.
- Optional work-unit automation is fail-closed: inspect/plan by default,
  require `-Execute` for workspace-state mutation, preserve dirty/divergent
  repositories, derive graph scope from the unit, and never own Git push,
  force-push, checkout/reset/stash, validation execution, or device mutation.
- One exact leading CRLF blank event record may be removed only through the
  typed `NormalizeEventLedgerPrefix` migration. It preserves every prior event
  byte and current-unit byte, appends one canonical event, changes only
  `state.last_event_id`, requires caller-pinned dry-run intent authority,
  publishes its receipt only after target readback, and keeps ordinary
  blank-record parsing strict. Route the complete procedure to
  `docs/EVENT_LEDGER_PREFIX_NORMALIZATION.md`.
- Move a reviewed proposal into the claimable queue only with the automation
  `Ready` action. It verifies accepted prerequisites, appends the transition,
  and derives `next_ready_unit`; when a current unit exists it must also prove
  the exact canonical supersession event ID fits the existing 128-character
  contract before any write. Withdraw only the exact next-ready unit through
  `WithdrawReady`: authenticate its original Ready transaction, preserve that
  event and current authority, derive the remaining queue, and record the
  ready-to-proposed withdrawal transaction and receipt. A withdrawn identity
  is retired from Ready; revise the proposal under a new unit identity. Do not
  hand-edit proposal status or ready-queue state.
- Mark an in-flight unit's declared instruction surfaces complete only through
  `CompleteInstructionSurfaces`. Replay the dry-run unit hash, stable
  observation hash, and complete planned-surface ID set; the executed action
  installs its receipt in the same transaction and never runs validation
  commands or changes unit fields other than those surface statuses.
- Correct an active unit's read-only parse/build closure only through
  `CorrectActiveReadOnlyDependencies` and the exact
  `active_read_only_dependency_correction.v1` contract. Require canonical
  state/unit and byte-exact event-ledger CAS, full before/after dependency
  sets, project-declared non-writable paths, and one resolvable full commit/tree
  identity for every resulting dependency. The transaction may change only
  `read_only_dependencies` plus `state.last_event_id`; it never materializes a
  worktree or runs a build. Route the full procedure to
  `docs/ACTIVE_READ_ONLY_DEPENDENCY_CORRECTION.md`.
- Correct the exact current active feature unit's legacy string or absent
  `architecture_decision` only through `CorrectActiveUnitContract` and the
  `active_unit_contract_correction.v1` input. Bind exact project revision and
  canonical hash, state, raw and canonical unit bytes, and event-ledger
  hash/length/tail; add only the fixed `rusty-morphospace` and
  `system-engineering` `review-no-change`/`planned` skill records. Preserve
  every other unit field and state field except `last_event_id`, retain a
  legacy selected string verbatim, require current feature compatibility before
  transaction, and install the correction receipt plus intent/completion/event
  atomically. Never use it as a generic editor, instruction completion,
  validation, acceptance, source, Git, remote, or device route. See
  `docs/ACTIVE_UNIT_CONTRACT_CORRECTION.md`.
- Correct an omitted project repository allow-list path only through
  `CorrectActiveProjectRepositoryScope` and the exact
  `active_project_repository_scope_correction.v1` contract. Require an exact
  current `active` unit, canonical project/lock/state/unit and byte-exact ledger
  CAS, complete before/after project path sets, and additions that exactly match
  paths already declared by that unit for the same repository. The v3
  transition must preserve the unit, atomically synchronize project revision,
  feature lock, and workspace registry, and never mutate source repositories.
  Route the full procedure to
  `docs/ACTIVE_PROJECT_REPOSITORY_SCOPE_CORRECTION.md`.
- Expand the current active feature unit within existing project repository
  authority only through `AmendActiveWriteScope` and the exact
  `active_write_scope_amendment.v1` contract. Require project/state/unit/event
  CAS, exact before/after path sets, at least one addition, a mutex-bound
  unchanged project spec, and dry-run input-hash replay. It may add a
  project-declared repository row but may not remove scope, edit project
  authority, change captain/status, or perform source, Git, build, validation,
  device, or remote work. Route the procedure to
  `docs/ACTIVE_WRITE_SCOPE_AMENDMENT.md`.
- Prepare a later feature envelope in an idle accepted project only through
  `PrepareDevelopmentEnvelope`, binding additive project/repository-root and
  feature/effect/permission/build/device ceilings plus a preparation-owned
  source-composition lock from the repository map. It never admits a future
  unit or performs source, build, device, or Git-remote work. Begin the feature
  only through `AdmitDevelopmentUnit`, binding that exact preparation receipt,
  prepared project, feature lock, source composition,
  repository map, state, and ledger preimages to its bounded agent assessment.
  Exact replay revalidates the same result; an interrupted owner transaction
  may recover it, while stale/conflicting evidence awaits independent rescue.
  The resulting proposal still follows ordinary Ready/Inspect/Claim. An
  admitted active unit must use `FreezeCandidate` before BeginValidation;
  historical units without the admission marker retain their existing route.
- Resolve one exact current active-unit blocker only through product-neutral
  `blocker_resolution_receipt.v1` and `ResolveBlocker`: revalidate its passing
  hash-bound evidence, attached-branch or exact detached repository heads, and
  exact per-repository dirty source bytes twice (including immediately before
  the ledger), preserve every other blocker and workflow projection, and use
  state/unit/event-tail CAS. Scan direct workflow receipts plus bound event
  references for replay; nested product evidence is not a resolution receipt.
  Product owner schemas may be referenced as evidence but never become generic
  workflow authority.
- New project workspaces default to protocol v2. Resolve exact feature
  descriptors into a fingerprinted closed-world lock. Descriptor filesystem
  locations are resolver inputs only; the lock records forward-slash paths
  relative to `project.spec.json` and rejects absolute, parent-traversing, or
  out-of-project locations. Project selection alone never activates a run.
  Runtime effects require the selected current lock and one descriptor-
  approved runtime input, and the effective marker/receipt must bind the
  project, lock revision/fingerprint, and feature.
- Before ref cleanup or byte-level source-policy adoption, run the read-only
  repository lifecycle advisory and route the full contract to
  `docs/REPOSITORY_LIFECYCLE.md`. Treat `candidate-retire` as evidence for a
  separate owner decision, never deletion authority; keep remote ref retirement
  separate from local worktree/branch cleanup and preserve incomplete, dirty,
  divergent, operational, or evidence-held refs.
- Enroll canonical text paths explicitly through repository-owned attributes;
  covered text is strict UTF-8 without BOM and LF-only, while historical and
  binary paths remain byte-exact until a separate reviewed conversion. Run the
  raw-byte preflight before hashing or signing and never let `core.autocrlf`
  normalize evidence. Route the full rule to `docs/AUTONOMOUS_ITERATION.md`.
- Automation may record or accept validation only from a workspace-local
  `validation_receipt.v1` with exact criterion/gate coverage, verified artifact
  hashes, current repo heads/branches, ancestor bases, exact changed paths, and
  required device cleanup plus zero bounded fatals. Reject missing, stale,
  spoofed, or out-of-scope evidence.
- Historical validation-debt self-tests must run direct child phases through
  create-new start/terminal/raw-stream evidence with finite child-tree cleanup
  and bounded diagnostics. Reuse only an exact baseline-evidence key binding
  validator, workspace/ledger anchor, source composition, current raw unit, and
  failure set. A history-archive checkpoint is integrity evidence only and
  never satisfies or authenticates historical validation debt.
- Recovery from a declared partial cross-repo commit, interrupted build, or
  interrupted device run requires `interruption_receipt.v1`. It must hash its
  evidence and prove preserved repo checkpoints plus safe build/device cleanup;
  recovery never performs Git, build-process, or device cleanup itself.
- A prepared push plan is never execution evidence. After an authorized
  external push, validate an `executed_push_receipt.v1` containing full old,
  new, and remote-readback revisions, ancestry, hash-bound validation evidence,
  no-force proof, and reverse-order rollback anchors. A release may additionally
  bind the pre-publication capture that supplied every old revision; multiple
  planning refs must form the final execution suffix.
- One exact pending plan that still records `execution: not-performed` may be
  retired only through `prepared_push_retirement.v1` and
  `RetirePreparedPush`. `PreparePush` must install its automation receipt as
  the transition's single byte-exact owned artifact; retirement must bind the
  identical artifact path, SHA-256, and payload from the immutable intent.
  Bind its immutable plan/event owner containers,
  complete stable clean repository observations, fresh remote readback, and
  the absence of recognized execution/publication evidence. Reject remotely
  reachable prepared ahead revisions. The route clears only the matching
  bundle, optionally one exact blocker, appends its typed event, and retains a
  hash-bound receipt; it never claims historical non-publication or weakens a
  publication/reconciliation route.
- If every distinct prepared revision is now ancestor-or-equal to its current
  intended remote ref, retirement must reject. Use only
  `prepared_publication_reconstruction.v1` and
  `ReconcilePreparedPublication`, with exact owner/member/event, accepted
  validation, canonical bundle/blocker, collapsed refs, and complete history.
- Correct an incomplete broader claim from an otherwise valid immutable
  blocker-resolution transaction only through the additive
  `blocker_resolution_correction_receipt.v1` and
  `CorrectResolvedBlockerEvidence`. The blocker must remain absent; bind the
  original event/receipt/intent/completion chain plus fresh exact source
  evidence, preserve every projection except `last_event_id`, and never edit
  the retained resolution.
- Repair a historical blocker-resolution raw binding across units only through
  `historical_blocker_resolution_intent_binding_correction.v1` and
  `CorrectHistoricalBlockerResolutionIntentBinding`. Admit only the exact
  legacy terminal LF-to-CRLF expansion on both the intent-owned receipt and
  completion-bound intent; bind the current active state/unit/event-ledger CAS,
  preserve every blocker and historical byte, and reject any second fault.
  Follow
  `docs/HISTORICAL_BLOCKER_RESOLUTION_INTENT_BINDING_CORRECTION.md`.
- Correct only the completed legacy-v1 supersession fault where the exact
  `<old>-superseded-by-<replacement>` event recorded the replacement in
  `event.unit_id` through `completed_transition_semantic_correction.v1` and
  `CorrectCompletedTransitionSemantics`. Derive both endpoints from retained
  state/unit evidence, require the original receipt and intent-artifact arrays
  to be empty, preserve every historical byte, and project the old endpoint
  only after the shared verifier authenticates both transaction chains. Route
  the complete procedure to
  `docs/COMPLETED_TRANSITION_SEMANTIC_CORRECTION.md`; never weaken ordinary v2
  supersession validation or hand-edit the malformed event.
- Protected-branch pre-push guards match Git's remote destination ref and
  resolve any explicit local selector to the exact attached protected branch
  revision before prepared-plan validation; deletion, detachment, mismatch,
  malformed input, and duplicate protected updates fail closed.
- `PreparePush` requires one distinct external planning repository containing
  the active project workspace. A source-only same-ref workspace may not claim
  planning-last closure. Its executed receipt output is installed by the same
  transition that appends the preparation event, never by a later overwrite.
  If a push preceded preparation, preserve chronology
  with `unplanned_publication_closure.v1` and the workflow-only
  `ReconcilePublication` transition; never fabricate a plan or mutate Git from
  recovery.
- If planning alone published early while every source remains unpublished,
  preserve the fault through `publication_ordering_interruption.v1` and create
  a fresh exact-ref plan; never claim that checkpoint was planning-last.
- A planned publication closes only through `RecordPublication` with a
  validated `planned_publication_accounting.v1`. It must enumerate the exact
  old-exclusive/final-inclusive commit sequence and carried-unit status, allow
  only one explicit planning-transport suffix, and clear only the matching
  bundle after clean no-force readback. See
  `docs/PLANNED_PUBLICATION_ACCOUNTING.md`.
  A source integration may use an empty merge-entry path list only for the
  typed exact two-parent topology: retain the preceding side/content commit's
  full triggering-unit attribution and verify ordered parents/trees, merge
  base, all four path projections, and the empty plain merge projection.
  Ordinary linear or untyped merge entries remain nonempty.
  Prepared provenance may bind standalone files or the exact `push_plan`
  member and transition-ledger event inside hash-bound owner containers; never
  reconstruct those members outside their immutable evidence containers.
  Live closure remains remote-exact except for the documented clean planning-
  only prerequisite suffix containing exactly the bound executed-push and
  accounting receipts; source ahead state and every unrelated path reject.
- If the receipt-only prerequisite suffix was already published without force
  before `RecordPublication`, use only `ReconcilePublishedPrerequisiteSuffix`:
  v1 admits one exact commit, while v2 admits exactly two linear full-ID commits
  when the second corrects only the accounting receipt. Bind the unchanged
  planned accounting and final receipt hashes, exact parent/current refs, clean
  unchanged sources, and no-force history; never admit other counts, paths,
  gaps, merges, abbreviations, duplicates, drift, or rewrites.
- If immutable no-force execution evidence predates its recorded PreparePush
  timestamp, typed integration topology does not repair chronology. Keep
  `RecordPublication` strict and use only
  `ReconcileExecutedPreparedPublication`: bind the original containers and
  timestamps, exact live refs, complete path-set fingerprints, and ordered
  merge parents/per-parent projections; claim neither corrected chronology nor
  flattened history. See
  `docs/EXECUTED_PREPARED_PUBLICATION_RECONCILIATION.md`.
- If normal linear source publication and one clean planning receipt-only
  commit are complete but exactly the five transaction-owned `PreparePush`
  paths remain dirty, keep `RecordPublication` strict. Use only the externally
  signed `ReconcilePreparedPushTransactionSuffix` route for the exact pending
  bundle; preserve all evidence bytes/timestamps and claim no Git, acceptance,
  execution, or publication authority. See
  `docs/PREPARED_PUSH_TRANSACTION_SUFFIX_RECONCILIATION.md`.
- A later force-with-lease replacement of an already published planning-only
  finalization suffix uses only the additive
  `planning_suffix_rewrite_recovery.v1` incident route. Bind both commits and
  trees, the common prepared parent, exactly two common parent-relative paths,
  exactly one replacement-delta path, current readback, and unchanged source
  refs; never route source rewrites or ordinary accounting through it.
- Seal a coordinated release with `release_capsule.v1`: exact remote equality
  and branch convergence belong to the candidate cut, while later historical
  closure requires ancestor-or-equal remote refs and an isolated exact clean
  tree. Observe active worktrees without mutating them or treating overlays as
  release payload. Route details to
  `docs\RELEASE_CAPSULE_AND_HISTORICAL_CLOSURE.md`.
- A downstream adoption unit must be behavior-neutral unless its scope says
  otherwise: select the baseline shell, list optional families disabled,
  assert an unrelated nearby feature is absent/inert, and add candidate records
  before moving reusable source.
- Units changing authority, module layout, activation, validation, device
  policy, repo routing, or public/private boundaries must synchronize the
  nearest repo instructions, a README/router doc, and relevant skills before
  acceptance.
- Derive the complete minimum instruction-surface set from the unit's routing;
  do not update unrelated skills merely because one router changed.
- Keep `AGENTS.md` and `SKILL.md` as routing indexes. Put long recipes in linked
  docs or runbooks.

## Validation

Affected-selector trust-root validation must use the registry-owned phased
runner and exact phase terminals described in `docs/AFFECTED_VALIDATION.md`.
Do not replace a failed phase with the legacy cumulative selector, raise a
phase budget to hide a blocker, or replay an already authenticated passing
phase. Preserve the deterministic phase directory with hosted evidence and
continue only from exact dependency- and runner-bound receipts.

Before committing, run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PowerShellHost.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublicBoundary.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ProjectWorkspace.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkUnitAutomation.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkUnitHandoff.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CorrectActiveReadOnlyDependencies.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CorrectActiveProjectRepositoryScope.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CorrectActiveUnitContract.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-EventLedgerPrefixNormalization.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CompletedTransitionSemanticCorrection.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-HistoricalBlockerResolutionIntentBindingCorrection.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-UnpublishedPlanningAuthorityMaterialization.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FeatureLockResolver.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ProjectIsolation.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExecutedPushReceipt.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ReleaseCapsule.ps1 -SelfTest
git diff --check
```

Multi-accepted publication accounting retains one prepared trigger. Additional
accepted units already in the immutable executed range use only the exact
partition documented in `docs/PLANNED_PUBLICATION_ACCOUNTING.md`; never relabel
the trigger or weaken blocked carried-unit rules.

If docs or manifests change, also parse JSON files:

```powershell
Get-ChildItem .\manifests,.\schemas,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```
