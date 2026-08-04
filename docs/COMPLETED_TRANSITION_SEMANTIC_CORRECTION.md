# Completed-Transition Semantic Correction

`CorrectCompletedTransitionSemantics` is one append-only workflow-owner
correction for a completed legacy-v1 supersession transaction whose event ID
correctly says `<old>-superseded-by-<replacement>`, but whose `event.unit_id`
incorrectly records the replacement. It does not make malformed
supersessions generally acceptable.

Version 1 recognizes only fault
`legacy-v1-supersession-event-unit-id-targeted-replacement`. The original
event must still be both the state and ledger tail when the receipt is built,
must have no receipts, and must come from a completed v1 transition intent
with no artifacts. The retained old and replacement units must both be
`active` or `validating`. Ordinary supersession creation remains strict:
`event.unit_id` is the old unit, `target.state.current_unit` is the replacement,
and the exact event ID is derived from those independently bound endpoints.

## Receipt authority

The strict
`rusty.morphospace.workflow.completed_transition_semantic_correction.v1`
receipt binds:

- the exact original event-ledger bytes, length, SHA-256, sequence, and tail;
- the embedded target state and retained old/replacement unit documents with
  canonical SHA-256 values and canonical workspace paths;
- the original intent and completion file paths and raw SHA-256 values;
- the independently derived effective old and replacement unit IDs; and
- the deterministic correction event ID, sequence, timestamp, unit, and sole
  receipt path.

The builder derives both semantic endpoints. It exposes no old-unit,
replacement-unit, or original-event override.

Create an inspected receipt outside the project workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>\scripts\New-CompletedTransitionSemanticCorrection.ps1 `
  -WorkspaceRoot <project-root>\morphospace `
  -OutPath <review-root>\completed-transition-correction.json
```

Review the receipt and its SHA-256. A builder result is a plan, not execution
evidence.

## Dry run and execution

Dry run revalidates every retained binding and reports the planned automation
receipt without changing the workspace:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectCompletedTransitionSemantics `
  -WorkspaceRoot <project-root>\morphospace `
  -CompletedTransitionSemanticCorrection <review-root>\completed-transition-correction.json `
  -OutPath <project-root>\morphospace\receipts\completed-transition-semantics-corrected-<sequence>.json
```

Execution requires the same inspected input, the exact receipt-derived
workspace output path, and `-Execute`. The input and installed output must be
distinct. The shared transition ledger applies state, unit, event-tail,
ledger-byte-hash, and ledger-length CAS under its workspace mutex. It installs
the exact input bytes as the transition's only artifact, changes only
`workspace.state.json.last_event_id`, preserves both unit documents, and
appends exactly one v1 `state-transition` event with exactly one receipt.

The original event, original transaction files, and original event-ledger
prefix are never rewritten. Git refs, repositories, validation, acceptance,
packages, devices, and external systems are outside this action's authority.

## Recovery and projection

If execution stops after intent, artifact, projection, or event append, repeat
the same executed command. Recovery first authenticates the complete receipt,
the unchanged historical prefix, the exact pending intent and artifact bytes,
the permitted state/unit projection, and a ledger suffix that is only a byte
prefix of the deterministic event. It then uses the transition ledger's
forward repair. A committed completion rejects replay. Unknown suffixes,
changed evidence, a substituted receipt, a damaged pending intent, or an
unrelated state/unit projection fails closed.

`Test-WorkflowContracts.ps1` treats the malformed original event as an
old-to-replacement edge only after the shared verifier authenticates the
installed correction event, receipt, original chain, and correction chain.
A named receipt path alone never changes event semantics. Missing, malformed,
duplicated, or damaged correction evidence leaves the original event invalid.

Changes to this verifier or repair authority use the separate base-owned
admission path in `EXTERNAL_VALIDATION_AUTHORITY.md`: approve the exact
candidate change set statically from the trusted base before candidate code is
executed, and require independent review before merge.

## Validation

Run the focused suite:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>\scripts\Test-CompletedTransitionSemanticCorrection.ps1 `
  -SelfTest
```

It covers positive execution, non-mutating planning, typed CLI routing,
no-caller-patch derivation, exact historical-byte preservation,
last-event-only state change, authenticated WorkflowContracts projection,
all four interruption boundaries, forward repair, replay, path confinement,
CAS drift, damaged retained evidence, damaged pending intent, and forged
projection rejection.
