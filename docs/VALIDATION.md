# Validation

Use validation in layers. Do not run live device operations just to prove docs
or manifests parse.

All validation uses PowerShell `7.6` LTS or newer through `pwsh`. Start with
the host-policy check; Windows PowerShell 5.1 is supported only far enough to
emit the migration guidance from that check.

## Work Environment Repo

When changing receipt structure, action registration, or v2 receipt relations,
run the corresponding focused owner checks before freezing the candidate:

```powershell
pwsh -NoProfile -File ./scripts/Test-ValidationReceiptStructure.ps1 -SelfTest
pwsh -NoProfile -File ./scripts/Test-WorkflowActionRegistry.ps1 -SelfTest
pwsh -NoProfile -File ./scripts/Test-AutomationReceiptV2Compatibility.ps1 -SelfTest
```

The v2 receipt schema's action/transition relations are the registration owner.
Each relation binds its producer and independent owner test in
`x-workflow-owner`. The compatibility corpus reads that registration; it keeps
independent state-shape, invalid-pair, drift and preservation tests. To refresh
the existing enum projections after reviewing a relation change, run
`Test-WorkflowActionRegistry.ps1 -UpdateGenerated`, then the checks above.
The registry check also rejects missing CLI actions, absent producers, and tests
missing from affected validation. Register new imports and test dependencies
before the graph/import and dependency-closure phases of the final runner.
Shared consumer expectations in selector scenarios have one explicit fixture
definition; do not derive those expectations from the selector being tested.

When changing the source-only publication builder or lifecycle boundary, run
the complete builder/lifecycle rehearsal in
`Test-SourceOnlyPublicationInputs.ps1 -SelfTest`. It complements the existing
source-only recovery test and must pass before that changed boundary is
described as ready. These are boundary-specific checks, not a checklist for
every feature. Focused results on a dirty candidate are diagnostic; the frozen
candidate still follows the managed phased runner and trust-root admission.

### Ordinary local affected checkpoint

Run the touched owner checks and `git diff --check` while editing, then commit
one coherent candidate. From that same clean owner checkout, resolve a plan
against explicit full base and head commit identities. Use a new ignored local
output path outside source, Git metadata and input directories:

```powershell
pwsh -NoProfile -File ./scripts/Resolve-AffectedValidation.ps1 `
  -RepositoryRoot <clean-owner-root> `
  -BaseCommit <exact-base-commit> -HeadCommit <exact-head-commit> `
  -Tier Quick -OutPath <new-local-output>/plan.json
```

This is selection only: no validation check has run. The resolver requires
clean tracked working bytes and HEAD equal to the selected head; it binds base
ancestry, exact source trees and both registry identities. Do not substitute a
moving remote ref or treat a dirty edit as an exact checkpoint.

Inspect the returned plan before launching checks. For a saved plan:

```powershell
$affectedPlan = Get-Content -Raw <new-local-output>/plan.json | ConvertFrom-Json
$affectedPlan | Select-Object base, head, plan_sha256, requested_tier, `
  effective_tier, selection_mode, execution_permitted, budget | Format-List
$affectedPlan.selected_checks | Select-Object check_id, platforms, `
  minimum_tier, reasons, budget_seconds, cache_policy | Format-List
```

`Tier` requests a coverage level; the effective tier can be higher when the
selected obligations require it. Report that increase explicitly. Quick,
Standard and Deep are not latency promises. `budget.actual` sums registered
check ceilings; it is not measured or predicted wall time. Preserve required
checks even when their cost exceeds a caller's limit: defer execution and
report validation pending, rather than lowering coverage. No new global time
or fanout gate is implied.

Execute the saved plan for the actual host platform, using another new output
path. For a Windows host with selected Windows checks:

```powershell
pwsh -NoProfile -File ./scripts/Invoke-AffectedValidation.ps1 `
  -RepositoryRoot <same-clean-owner-root> `
  -BaseCommit <same-exact-base-commit> -HeadCommit <same-exact-head-commit> `
  -PlanPath <new-local-output>/plan.json -Platform windows `
  -OutPath <new-attempt-output>/windows.json
```

Use `-Platform linux` only on a Linux host. The executor recomputes the exact
plan before any child starts; a stale or altered plan cannot reuse the preview
as authority. If the host platform has no selected checks, do not invoke its
zero-check execution route: report not applicable and preserve the other
platform's pending obligations. A Windows pass covers only the exact Windows
selection; it does not establish Linux completion. Local check evidence does
not grant hosted validation, static admission, acceptance or publication.

For a corrected attempt, pass an existing finalized local check inventory with
`-PriorEvidenceDirectory <prior-check-evidence-directory>` and write to new
output paths. The executor authenticates every reusable leaf; a cache miss
runs the required check. See [Affected Validation](AFFECTED_VALIDATION.md#local-evidence-and-segment-retries)
for complete-inventory requirements, exact segment retries and platform merging.

### Explicit compatibility sweeps

`Test-WorkEnvironment.ps1 -SelfTest -Tier Quick`, `Standard` and `Deep` retain
their cumulative compatibility meanings. Use them when the aggregate itself
is selected or a full compatibility sweep is explicitly required; they are
not the default local affected checkpoint. Existing scheduled/manual coverage
is unchanged. When deliberately running cumulative Quick plus its Standard
delta, `Test-WorkflowContracts.ps1 -StandardDeltaOnly` retains the closed-child
automation launcher without replaying Quick. Do not follow cumulative Quick
with cumulative Standard. A standalone `Test-WorkUnitAutomation.ps1` remains
a low-level diagnostic requiring an already-closed child environment. A
device is not part of these coverage tiers.

During an edit loop, run only the focused owner test for the touched surface,
for example:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1 -SkipOwnerSelfTests
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PlannedPublicationAccounting.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PublishedPrerequisiteSuffixReconciliation.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExecutedPreparedPublicationReconciliation.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-SourceOnlyPublication.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExternalValidationAuthoritySelfTest.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ExternalOwnerAuthorization.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ProjectWorkspace.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-DocumentationLinks.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-SkillTemplates.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-UnpublishedPlanningAuthorityMaterialization.ps1 -SelfTest
```

Affected-validation ownership is a tracked-tree invariant. A coherent frozen
candidate must give every exact-HEAD path one path-set owner, every path set a
specialized trigger beyond `public-boundary`, and every registered command one
owner. It must also preserve exact argument parity between focused leaves and
the owners invoked by `Test-WorkEnvironment.ps1`. After committing the
candidate, run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-AffectedValidationOwnership.ps1 -SelfTest
```

The affected-validation registry is a mandatory protected path with its own
focused ownership and workflow-action checks. Selector implementation changes
select the full bounded selector closure; affected schema and structural
registry changes select the independent Deep obligations described in
[Affected Validation](AFFECTED_VALIDATION.md). Unknown or overlapping mappings
produce a typed `mapping-incomplete` plan with no selected checks, zero budget
and `execution_permitted=false`. Execution and merging reject that plan;
there is no executable broad fallback for incomplete ownership.

The source-only publication check is Windows-scoped because it authenticates
physical directory identity with volume serial and `FileIdInfo`. Its fixture
also runs `Test-WorkflowContracts.ps1 -CurrentWorkOnly -SkipOwnerSelfTests`
after both the prepared and recorded transitions. Those current-work checks
authenticate local ledger, artifact, unit, and state evidence without requiring
a planning remote or repeating live source publication observations.

Do not run the same broad suite on dirty and clean source solely to obtain
both receipt shapes. A dirty check is diagnostic. For handoff, freeze and
commit the coherent candidate, resolve its exact affected plan, and execute
the selected obligations with eligible finalized evidence reuse. If a repair
changes that commit, run the nearest failed check first, freeze the repair and
resolve a fresh exact plan; do not relabel earlier aggregate evidence.

For example, current skill-review compatibility compares the routed skill to
the owning repository's exact HEAD blob. Editing that skill can therefore make
the dirty diagnostic fail even when its structure is valid. Check the changed
template and links while editing, commit the reviewed bytes, then run the
exact-head check. Do not weaken its binding or demand a successful pre-commit
aggregate that depends on the as-yet uncommitted blob.
This also applies to focused suites that call those reviews, including
`Test-DevelopmentUnitAdmission.ps1`; a focused entrypoint is not necessarily
independent of HEAD. A known dirty-binding failure calls for freezing the
candidate, not another unchanged test attempt. The structural workflow check
uses `-SkipOwnerSelfTests`; select affected behavioral leaves separately.

Do not append all focused commands to every aggregate run. The aggregate owns
each expensive owner self-test once; nested temporary workspaces run structural
contract validation without recursively re-running unrelated owner suites.

Admission and recovered-proposal continuation have separate focused entrypoints:

```powershell
pwsh -NoProfile -File ./scripts/Test-DevelopmentUnitAdmission.ps1 -SelfTest
pwsh -NoProfile -File ./scripts/Test-AdmissionCompletionTimestampRecovery.ps1 -SelfTest
pwsh -NoProfile -File ./scripts/Test-RecoveredProposalContinuation.ps1 -SelfTest
pwsh -NoProfile -File ./scripts/Test-RecoveredPreparedAdmission.ps1 -SelfTest
pwsh -NoProfile -File ./scripts/Test-ProposedUnitRetirement.ps1 -SelfTest
```

Select the entrypoint affected by the change; this is not a list to run after
every edit. The continuation case composes owner-written admission, timestamp
recovery, retirement and fresh preparation in an isolated fixture. It is an
independent Windows affected-validation leaf with exact-host evidence. Direct
test edits select that test and public-boundary checks; shared fixture or
production changes select their actual consumers. A passing old admission
receipt does not stand in for the newly separated continuation result.
The prepared-admission leaf retains the original accepted checkpoint through
fresh Prepare, Admit, Ready, Inspect and Claim, including damaged-recovery
rejection without writes. The existing continuation entrypoint keeps its prior
later-acceptance scenario by default. Its explicit `-Scenario All` runs both;
affected Deep validation selects both independent leaves. The unchanged
compatibility aggregate keeps its original invocation and coverage.
The proposed-unit retirement leaf exercises the direct owner independently,
including dry/execute parity, authenticated admission recovery, CAS failures,
fault recovery, replay, strict receipt-format dispatch, preserved evidence,
transaction-identity bounds, canonical direct-owner timestamps, and hostile
private legacy-adapter rejection. The broad WorkUnitAutomation test separately
preserves the public legacy timestamp spelling and exact module/CLI result and
receipt bytes. Its transition intent/completion comparison normalizes only
ledger-owned wall-clock fields after independently authenticating each raw
artifact and completion reference.
The explicit full Quick and workflow owner-test aggregates retain the composed
case once. Affected CI invokes workflow contracts with `-SkipOwnerSelfTests`
and selects the independent leaf, so a failed continuation can be rerun without
replaying unrelated passing admission tests. Reuse still requires the existing
complete input and runner binding; no separate cache or receipt type is added.

Changes to a validation trust root use the separate base-owned static admission
contract in [External Validation Authority](EXTERNAL_VALIDATION_AUTHORITY.md).
That verifier examines fetched Git objects only and explicitly does not attest
candidate execution or authorize publication.

Active [Full Authority Mode](FULL_AUTHORITY_MODE.md) changes the user-to-agent
decision and prompting boundary, not validation selection or evidence. For a
protected validation-authority candidate, read both contracts: the delegated
agent may review, sign, and post each fresh exact owner request without another
prompt only when the activating user and signing source satisfy the external
owner policy. The base-owned verifier, selected dynamic checks, acceptance,
and publication boundaries remain unchanged.

Validate a configured contributor machine separately:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkEnvironment.ps1 `
  -ConfigPath .\local\local.paths.json `
  -Profile Core `
  -Strict
```

Use `-Profile Quest` when the Android SDK, NDK, JDK 17, and ADB toolchain are
required. Strict mode rejects required placeholders and missing configured repo
paths; Python 3.11 is required for every profile.

JSON parse:

```powershell
Get-ChildItem .\manifests,.\schemas,.\templates -Filter *.json -File |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
```

PowerShell parse:

```powershell
Get-ChildItem .\scripts -Filter *.ps1 -File |
  ForEach-Object {
    [scriptblock]::Create((Get-Content -Raw $_.FullName)) | Out-Null
  }
```

## Project Workflow Contracts

The workflow validator checks more than JSON syntax. It enforces:

- closed-world activation and declared-module references;
- one authority owner per parameter;
- module maturity and iteration state vocabularies;
- repository/path scope, non-scope, acceptance, risk, device, and push fields;
- at most one active unit and consistent compact state;
- increasing, parseable JSONL iteration events;
- stable-promotion gates, rollback, and an independent consumer or
  conformance harness;
- required instruction synchronization for authority, module-layout,
  activation, validation, device-policy, repo-routing, and boundary changes.
- exact-lock/materialization source modes, resource requirements, repository
  revision checkpoints, and extraction-bound v2 stable promotions.

Validate an instantiated project workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot <project-root>\morphospace
```

The checked-in v2 onboarding workspace is a semantic regression target:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot .\examples\hello-morphospace-v2\morphospace
```

The scaffold self-test creates a temporary project workspace, validates it,
proves that a second invocation cannot overwrite it, and removes only its own
temporary directory.

The project-isolation test creates two temporary Git repositories, locks their
exact commits and trees, materializes detached clean copies, rejects address
replacement, and proves that overlapping exclusive local resource claims fail
closed. It performs no device operations.

The feature-lock resolver self-test proves dependency closure, descriptor and
source hashing, exact effect unions, selected-lock-plus-runtime-input
activation, absent-feature rejection, ambient-input rejection, and stale-lock
fingerprint rejection.

Work-unit automation self-tests keep missing/spoofed validation receipts,
dirty-path overlap, and out-of-scope changed paths as hard failures. A passing
device receipt is incomplete without explicit serial scope, cleanup, and zero
bounded package/system fatal counts.
They also simulate partial cross-repo commits, interrupted builds, and
interrupted device work: missing/unsafe cleanup receipts reject, while typed
safe receipts restore only the current-unit pointer and leave Git/devices
untouched.

## Executed Push Receipts

Validate externally produced successful push evidence with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExecutedPushReceipt.ps1 `
  -Path <project-root>\morphospace\receipts\<executed-push-receipt>.json
```

The semantic validator requires dependency order to equal actual execution
order, exactly one planning ref last, full old/new/readback revisions, exact
remote equality, fast-forward ancestry, no force push, passing referenced
validation gates, and rollback points that exactly reverse execution order.
It does not execute Git or contact a remote.

## Unplanned Publication Recovery

Validate the additive recovery contract with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-UnplannedPublicationClosure.ps1 `
  -Path <planning-workspace>\receipts\<closure>.json `
  -WorkspaceRoot <planning-workspace> `
  -RepoMapPath <local-repository-map>
```

The validator requires a hash-bound pre-recovery workspace, passing validation
evidence, a clean synchronized source ref, exact old/new/readback and rollback
revisions, verified fast-forward ancestry, no force push, and an external
observer. Its self-test proves evidence tampering rejects. The recovery action
changes workflow state only and never performs Git.

For a published embedded workspace with null activity and pending-bundle state
but a stale dirty source projection, validate the distinct adoption contract:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-PublishedPlanningAuthorityAdoption.ps1 -SelfTest
```

The focused suite proves exact projection and state hashes, the stale-to-clean
source-head delta, clean attached synchronized source evidence, a clean
distinct local-only planning authority, preservation of unrelated state, and
one-time workflow-only execution. It rejects state substitution, identity or
remote drift, extra dirty-marker clearing, repeated adoption, and fabricated
plan, push, acceptance, or Git claims.

## Source Repos

Each source repo owns its own checks. Typical Rust checks:

```powershell
cargo fmt --all --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

For broad repo-family orientation, start with a tracked-file inventory before
deeper graph or pattern scans.

## Quest Device Work

Live device validation is not a docs check. Use the public Meta Quest workflow
and record:

- provider used;
- command goal;
- selected device placeholder;
- foreground before and after;
- install/launch/logcat/screenshot/Perfetto commands, if used;
- artifact types and cleanup state.

Keep raw device artifacts private unless a public redaction gate exists.
