# Validation

Use validation in layers. Do not run live device operations just to prove docs
or manifests parse.

All validation uses PowerShell `7.6` LTS or newer through `pwsh`. Start with
the host-policy check; Windows PowerShell 5.1 is supported only far enough to
emit the migration guidance from that check.

## Work Environment Repo

Before freezing a workflow change, run the touched receipt and action checks:

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

For source publication, also run the complete builder/lifecycle rehearsal in
`Test-SourceOnlyPublicationInputs.ps1 -SelfTest`. It complements the existing
source-only recovery test and must pass before a shared candidate is described
as ready. Focused results on a dirty candidate are diagnostic; the frozen
candidate still follows the managed phased runner and trust-root admission.

Quick checkpoint:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PowerShellHost.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkEnvironment.ps1 -SelfTest -Tier Quick
git diff --check
```

Standard delta, after a passing Quick checkpoint when the changed boundary
requires it:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1 -StandardDeltaOnly
```

`Quick` covers portable contracts, scaffolding, skill bootstrap, and docs. The
canonical closed-child route above adds the Standard work-unit automation coverage
without replaying Quick. `Test-WorkEnvironment.ps1 -SelfTest -Tier Standard`
remains a cumulative compatibility aggregate for callers that have not already
run Quick; do not invoke it after the Quick checkpoint. `Deep` adds the
closed-room validation-authority suites and should run only when that risk is
in scope. A device is not part of any of these tiers. A standalone
`Test-WorkUnitAutomation.ps1` invocation is a strict low-level diagnostic that
requires its caller to have already constructed a closed environment; it is
not the public local Standard route.

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

The source-only publication check is Windows-scoped because it authenticates
physical directory identity with volume serial and `FileIdInfo`. Its fixture
also runs `Test-WorkflowContracts.ps1 -CurrentWorkOnly -SkipOwnerSelfTests`
after both the prepared and recorded transitions. Those current-work checks
authenticate local ledger, artifact, unit, and state evidence without requiring
a planning remote or repeating live source publication observations.

Do not execute the same risk-selected aggregate on dirty source and again on
clean source solely to obtain both receipt shapes. A dirty aggregate is an
explicit diagnostic. For handoff, freeze and commit the coherent candidate,
then run the smallest sufficient aggregate once against its exact base. If a
repair changes that commit, rerun the nearest failed check first and execute
the aggregate once for the repaired candidate.

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
pwsh -NoProfile -File ./scripts/Test-ProposedUnitRetirement.ps1 -SelfTest
```

Select the entrypoint affected by the change; this is not a list to run after
every edit. The continuation case composes owner-written admission, timestamp
recovery, retirement and fresh preparation in an isolated fixture. It is an
independent Windows affected-validation leaf with exact-host evidence. Direct
test edits select that test and public-boundary checks; shared fixture or
production changes select their actual consumers. A passing old admission
receipt does not stand in for the newly separated continuation result.
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
