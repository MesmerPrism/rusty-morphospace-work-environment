# Historical Supersession Compatibility

`RecordHistoricalSupersessionCompatibility` is a narrow append-only owner
action for one idle workspace whose retained history contains this exact
authenticated shape:

1. one canonical old-to-replacement supersession event with no intent or
   completion files;
2. the immediately following completed event-ledger prefix normalization;
3. the immediately following completed legacy-v1 replacement-to-successor
   supersession; and
4. one committed acceptance transition for that successor.

The action does not make transactionless or legacy-v1 supersessions generally
valid. Ordinary and future supersessions remain strict v2. The proof is
eligible only when the old and replacement units are immutable, non-current,
non-next `active` or `validating` history and the live workspace is idle.

The verifier authenticates the normalization's embedded pre-ledger and
pre-state, its exact intent, completion, receipt, target event, and target
state. It then proves that the transactionless event is the normalization's
immediate predecessor and that no files have been fabricated for its absent
transaction. The legacy-v1 successor must consume the normalization's exact
target state and ledger identities, preserve the old unit projection, create
exactly the active successor unit plus its source-composition lock, and retain
its original completion. Finally, the ordinary transition owner must
authenticate the accepted endpoint.

The normalization may preserve historical CRLF-framed ledger bytes while a
Git checkout presents equivalent LF-framed rows. Raw hashes therefore bind
each preserved byte source in its own domain; canonical document hashes prove
that every historical and live event row is identical in meaning. Raw and
document hashes are never substituted for each other.

## Build, review, dry run, and execute

Build the closed compatibility input outside the project workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/New-HistoricalSupersessionCompatibility.ps1 `
  -WorkspaceRoot <project-root>/morphospace `
  -OldUnitId <transactionless-old-unit> `
  -ReplacementUnitId <transactionless-replacement-unit> `
  -NormalizationId <normalization-event-id> `
  -CompatibilityId <new-compatibility-event-id> `
  -OutPath <review-root>/historical-supersession-compatibility.json
```

Review the generated file and its SHA-256. Dry run revalidates all evidence and
returns that exact input hash without mutating the workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action RecordHistoricalSupersessionCompatibility `
  -WorkspaceRoot <project-root>/morphospace `
  -HistoricalSupersessionCompatibility <review-root>/historical-supersession-compatibility.json `
  -OutPath <project-root>/morphospace/receipts/<new-compatibility-event-id>.json
```

Execution requires the reviewed hash and the same input and output paths:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action RecordHistoricalSupersessionCompatibility `
  -WorkspaceRoot <project-root>/morphospace `
  -HistoricalSupersessionCompatibility <review-root>/historical-supersession-compatibility.json `
  -ExpectedHistoricalSupersessionCompatibilitySha256 <reviewed-sha256> `
  -OutPath <project-root>/morphospace/receipts/<new-compatibility-event-id>.json `
  -Execute
```

The v5 transition raw-binds the old-unit preimage, installs the reviewed input
as its sole artifact, appends one receipt-bearing state-transition event, and
changes only `workspace.state.json.last_event_id`. It never creates the missing
historical transaction, rewrites either historical unit, or performs source,
Git, build, device, remote, validation, acceptance, or publication work.

Exact committed replay revalidates the same result. An interrupted execution
may resume only its exact pending intent, artifact, permitted state projection,
and deterministic event prefix. Any altered unit, normalization artifact,
legacy-v1 successor, accepted endpoint, proof receipt, transaction suffix, or
live preimage fails closed.

After installation, development-envelope preparation may consume the receipt
as exactly two historical closure edges: the proved transactionless edge and
the proved legacy-v1 successor edge. No other owner or validator receives a
general compatibility exemption.

## Validation authority

This action extends workflow trust-root authority. Changes follow the two-stage
external validation process in `EXTERNAL_VALIDATION_AUTHORITY.md`: trusted-base
Static admission of the exact candidate path/hash set, followed by a separate
candidate-side dynamic run. Neither stage alone grants publication authority.
