# Admission Completion Timestamp Recovery

`RecoverAdmissionCompletionTimestamp` is a narrow append-only workflow-owner
repair for one ordinary development-unit admission that installed every
declared artifact and projection but wrote a completion timestamp earlier than
its immutable, explicitly future-dated intent. It does not make malformed
transactions generally acceptable.

The v1 recovery accepts only fault
`admission-completion-precedes-future-intent`. The admission event must remain
both the state and event-ledger tail. Its unit must remain `proposed`, the
workspace must remain idle, and the original admission request, recovered
preparation receipt, preparation receipt, source-composition lock, repository
map, admission receipt, intent, malformed completion, project, feature lock,
state, unit, and event-ledger prefix must all retain their exact raw and
canonical SHA-256 identities.

The verifier proves that the admission receipt is byte-identical to the
inspected request; the intent owns that exact receipt; its state, unit, event,
and ledger append are fully derivable; and the completion-to-intent chain is
valid in every field except `completed_at < created_at`. Any second defect,
alternate chronology, missing artifact, byte drift, path substitution, state
change, event suffix, or repeated repair rejects.

## Inspect, dry run, and execute

Build the recovery outside the project workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/New-AdmissionCompletionTimestampRecovery.ps1 `
  -WorkspaceRoot <project-root>/morphospace `
  -OutPath <review-root>/admission-completion-recovery.json
```

When the malformed admission event is future-dated relative to the host, the
builder uses that exact immutable intent timestamp for the correction event.
It never accepts another caller-selected future timestamp.

Dry run revalidates the complete evidence set and returns the input's exact
audit SHA-256 without changing the workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action RecoverAdmissionCompletionTimestamp `
  -WorkspaceRoot <project-root>/morphospace `
  -AdmissionCompletionTimestampRecovery <review-root>/admission-completion-recovery.json `
  -OutPath <project-root>/morphospace/receipts/admission-completion-timestamp-recovered-<sequence>.json
```

Execution requires the dry-run SHA-256 through
`-ExpectedAdmissionCompletionTimestampRecoverySha256`, the same inspected
input, the receipt-derived output path, and `-Execute`.

The transition raw-binds state and unit preimages plus unchanged project and
feature-lock projections. It installs the inspected recovery bytes as its sole
artifact, changes only `workspace.state.json.last_event_id`, and appends one
typed state-transition event. The original malformed completion and every
admission/preparation artifact remain byte-for-byte unchanged.

The action grants no Ready, Claim, write scope, source, validation, acceptance,
Git, build, device, remote, or publication authority. Normal admission remains
strict. If execution is interrupted, only the exact pending recovery intent,
artifact, permitted state projection, and deterministic event prefix can move
forward through transition-ledger repair.

## Validation authority

This action and its validator alter workflow recovery authority. Changes use
the two-stage external validation process in
`EXTERNAL_VALIDATION_AUTHORITY.md`: trusted-base static admission of the exact
candidate path/hash set, then separate candidate dynamic execution. Neither
stage alone grants publication authority.
