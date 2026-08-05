# Correcting a historical blocker-resolution intent binding

`CorrectHistoricalBlockerResolutionIntentBinding` is the narrow append-only
route for one legacy transaction signature: a retained blocker-resolution
receipt and transition intent have a terminal CRLF where the immutable intent
artifact and completion recorded the same bytes with a terminal LF. It is not
a generic JSON-equivalence, hash replacement, or historical migration action.

The correction is cross-unit by design. A different current unit may own the
repair while the historical event, receipt, intent, completion, and historical
unit remain unchanged. The inspected correction binds the exact current active
unit, raw and canonical state/unit hashes, complete ordered blocker set, and
event-ledger byte hash, length, tail, and sequence. It separately binds the
historical event identity and canonical hash plus the raw hashes and canonical
paths of its receipt, intent, and completion.

Validation admits only the exact terminal-newline signature. Removing the
terminal carriage return from the retained receipt must reproduce both the
intent-owned receipt bytes and hash. Removing it from the retained intent must
reproduce the completion-recorded intent hash. The original receipt must still
satisfy its schema and identity; its intent-owned bytes, event placement,
embedded target state/unit hashes, and every completion field other than the
recorded intent file hash must remain exact. Any additional byte or semantic
fault rejects.

Replay parses and hash-checks the event-ledger prefix ending at the correction's
bound pre-append tail, so the historical target must already exist inside that
prefix. Both the retained legacy transaction and the additive correction
transaction require their exact v1 property sets, reference paths, pre/expected
and target hashes, one-and-only-one owned artifact, strict timestamps, and an
exact completion shape. Unknown fields, additional artifacts, malformed or
reversed transaction chronology, and post-prefix targets reject.

Build an inspected input outside the project workspace:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/New-HistoricalBlockerResolutionIntentBindingCorrection.ps1 `
  -WorkspaceRoot <project-root>/morphospace `
  -HistoricalEventId <historical-blocker-resolved-event-id> `
  -ReceiptId <correction-receipt-id> `
  -Timestamp <reviewed-utc-timestamp> `
  -OutPath <local-inspected-correction.json>
```

Dry-run the public action and retain its `audit_receipt.sha256`:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectHistoricalBlockerResolutionIntentBinding `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <current-active-unit-id> `
  -HistoricalBlockerResolutionIntentBindingCorrection <local-inspected-correction.json> `
  -OutPath <project-root>/morphospace/receipts/<correction-receipt-id>.json
```

Execute only the same reviewed bytes:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectHistoricalBlockerResolutionIntentBinding `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <current-active-unit-id> `
  -HistoricalBlockerResolutionIntentBindingCorrection <local-inspected-correction.json> `
  -ExpectedHistoricalBlockerResolutionIntentBindingCorrectionSha256 <dry-run-sha256> `
  -OutPath <project-root>/morphospace/receipts/<correction-receipt-id>.json `
  -Execute
```

The transition ledger installs the input receipt, appends one event on the
current unit, and changes only `workspace.state.json:last_event_id`. It binds
the mutex-protected state/unit canonical hashes and the full pre-append event
ledger hash and length. Current unit bytes, blockers, validation, pending
publication, and all historical bytes remain unchanged. Later replay accepts
the two raw bindings only through one authenticated correction; missing,
duplicated, altered, or transaction-damaged correction evidence fails closed.

Run `scripts/Test-HistoricalBlockerResolutionIntentBindingCorrection.ps1
-SelfTest` and the full workflow contract suite before adopting this action.
