# Prepared-Push Transaction-Suffix Reconciliation

`ReconcilePreparedPushTransactionSuffix` is a narrow, externally authorized
workflow-state recovery for one accepted, non-current unit. Use it only when
all source owners followed the normal linear publication shape and the
planning owner already committed the executed-push and planned-accounting
receipts, but `PreparePush -Execute` then left its five transaction-owned paths
as the only planning-worktree changes.

This action is not an alternative publication workflow. Ordinary
`RecordPublication` remains strict and unchanged. The action performs no Git
operation and makes no execution, acceptance, or publication claim.

## Eligible shape

The signed reconciliation must bind one exact pending bundle and prove all of
the following:

- the unit is accepted, is not current, and its raw and canonical bytes match;
- the state, complete event ledger, and preparation tail match raw and
  canonical CAS values;
- the prepared plan, transition intent, and transition completion are the
  immutable containers created by the current `PreparePush` transaction;
- the executed-push receipt and planned-publication accounting receipt match
  by path, byte length, and SHA-256 and pass their ordinary validators;
- every source owner is clean at one exact linear commit whose sole parent,
  tree, branch, upstream, and remote readback match the plan and receipts;
- the planning owner is at exactly one receipt-only commit above its execution
  final, and that commit changes only the executed-push and accounting receipt
  paths; and
- the planning worktree has exactly these five changes, with no sixth path:
  `iteration-events.jsonl`, `workspace.state.json`, the prepared-plan receipt,
  the preparation intent, and the preparation completion.

The five paths are compared as exact repository-relative paths with status,
byte length, and SHA-256. Missing, extra, case-aliased, reordered, substituted,
or drifted evidence rejects.

The transition clears only the matching `pending_push_bundle`, updates
`last_event_id`, appends one event and its transaction intent/completion, and
installs the signed reconciliation as its sole audit artifact. The target unit
document and every pre-existing receipt, event byte, timestamp, validation
result, and acceptance result remain unchanged.

## External owner authorization

The public contract contains no project-specific exception. Instead, a pinned
external owner signs one canonical authorization payload containing the exact
project, unit, bundle, reconciliation scope hash, authorization identity,
freshness window, decision, and fixed limitations. A changed byte, bundle,
unit, expiry, limitation, or authorization identity invalidates the signature.
Another bundle requires a separately admitted owner authorization.

Keep the unsigned draft, signed input, repository map, live hashes, local
paths, and resulting receipt in the adopting project's ignored control/evidence
space. Do not copy those values into this repository.

Create the signed input with the pinned owner key:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\New-PreparedPushTransactionSuffixAuthorization.ps1 `
  -DraftPath <ignored-draft.json> `
  -AuthorizationId <owner-approved-id> `
  -IssuedAt <strict-utc-seconds> `
  -ExpiresAt <strict-utc-seconds> `
  -PrivateKeyPemPath <owner-key.pem> `
  -OutPath <ignored-signed-input.json>
```

The certificate-store form uses `-CertificateThumbprint` instead of
`-PrivateKeyPemPath`. The output is no-overwrite and must satisfy
`prepared-push-transaction-suffix-reconciliation-v1.schema.json`.

## Two-phase execution

Dry-run first and compare the returned audit hash with the signed input:

```powershell
$invoke = '.\scripts\Invoke-WorkUnitAutomation.ps1'
$plan = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $invoke `
  -Action ReconcilePreparedPushTransactionSuffix `
  -WorkspaceRoot <planning-workspace> `
  -UnitId <exact-unit-id> `
  -RepoMapPath <ignored-repository-map.json> `
  -PreparedPushTransactionSuffixReconciliation <ignored-signed-input.json> `
  -OutPath <workspace-receipt.json> |
  ConvertFrom-Json

$inputSha = (Get-FileHash -Algorithm SHA256 `
  -LiteralPath <ignored-signed-input.json>).Hash.ToLowerInvariant()
if ($plan.executed -or $plan.audit_receipt.sha256 -cne $inputSha -or
    $plan.preservation.git_mutation_performed -or
    $plan.preservation.device_mutation_performed -or
    $plan.preservation.remote_mutation_performed) {
  throw 'Prepared-push transaction-suffix dry-run review failed.'
}
```

Replay the same signed bytes with their expected hash:

```powershell
$result = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $invoke `
  -Action ReconcilePreparedPushTransactionSuffix `
  -WorkspaceRoot <planning-workspace> `
  -UnitId <exact-unit-id> `
  -RepoMapPath <ignored-repository-map.json> `
  -PreparedPushTransactionSuffixReconciliation <ignored-signed-input.json> `
  -ExpectedPreparedPushTransactionSuffixReconciliationSha256 `
    $plan.audit_receipt.sha256 `
  -OutPath <workspace-receipt.json> `
  -Execute |
  ConvertFrom-Json

if (-not $result.executed -or $result.current_unit_after -ne $null) {
  throw 'Prepared-push transaction-suffix reconciliation did not close.'
}
```

After execution, revalidate the workspace, require the pending bundle to be
absent, and record exact state, ledger, event, intent, completion, and audit
receipt hashes. Git publication and any later branch integration remain
separate owner operations.

## Rejection and nonclaims

Reject the route when ordinary `RecordPublication` can truthfully close the
bundle, any source is dirty or non-linear, the planning suffix has another
commit or path, the worktree differs from the exact five-path shape, the unit
is current, the bundle does not match, or any signature/CAS/evidence binding is
stale. Do not adapt the contract to a nearby incident.

The reconciliation does not:

- change source or Git state;
- repair or reorder timestamps;
- rewrite the event prefix or unit;
- run validation, accept work, or publish a ref;
- authorize a different bundle; or
- weaken `RecordPublication`, retirement, reconstruction, or existing
  publication-recovery routes.

Validate the reusable contract with:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-PreparedPushTransactionSuffixReconciliation.ps1 `
  -SelfTest
```
