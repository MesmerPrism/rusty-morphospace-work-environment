# Exact normal-validation selector

`BeginValidation` normally exposes the validation gates declared by the selected
iteration unit. An immutable frozen unit may use one additive external selector
only when a separately reviewed planning-control-plane repair cannot change the
unit's raw bytes. This is a dispatch-planning capability, not a general command
override.

The caller supplies all three selector arguments together for dispatch and must
repeat the exact same arguments for `ReturnToActive`, `RecordValidation`, and
the first successful `Accept` that consume the resulting receipt:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action BeginValidation `
  -WorkspaceRoot <project-root>/morphospace `
  -UnitId <unit-id> `
  -ValidationTier quick `
  -ValidationSelector validation-authority/selectors/<selector-id>.json `
  -ExpectedValidationSelectorSha256 <selector-sha256> `
  -ValidationEvidencePath <absolute-external-create-new-evidence-path>
```

The selector is data-only. It cannot contain a command. It binds the exact raw
`project.spec.json`, the dispatch-time raw iteration unit plus a canonical unit
contract hash that excludes only lifecycle `status`, one original unit validation profile and
command hash, candidate-freeze marker and receipt, ordered final repository
commit/tree identities, workspace-relative PowerShell producer path and bytes,
and the expected evidence file name/schema plus canonical absolute path digest.
The selector file leaf must exactly equal `selector_id`. The consumer synthesizes the only
permitted invocation shape and returns it in the original gate's matrix row.
The original `gate_id` and `profile_id` remain unchanged and the selector
identity, producer identity, and output evidence identity are explicit.

Selection is limited to the Quick tier. Dispatch is limited to `BeginValidation`;
receipt consumption is limited to `ReturnToActive`, `RecordValidation`, and
`Accept`. The selector must
be a non-reparse-point file under `validation-authority/selectors/`; the producer
must be a non-reparse-point `tools/*.ps1` leaf. The evidence path must be
absolute, outside the planning workspace, have the exact selected file name,
have an existing parent, match the selector's canonical path digest, and not
already exist at dispatch. An executed dispatch persists only the unit ID,
dispatch-time raw-unit SHA, status-independent unit-contract SHA, tier,
selector ID/path/SHA, and evidence-path SHA in workspace state—never a command.
Receipt consumers must reproduce that exact binding, require the evidence file
to exist, permit only the expected lifecycle status change in the live unit,
revalidate evidence schema and bytes, and require the selected gate to
reference that exact hashed artifact. Any absent companion argument,
raw-byte drift, hash mismatch, gate ambiguity, receipt/candidate mismatch,
unexpected property, producer drift, tier/action mismatch, path escape, or
evidence collision, omission, or post-dispatch selector/evidence drift rejects
without fallback. A returned or blocked attempt needs a fresh exact selector
and create-new evidence path for its next dispatch; replaying an existing path
is a collision.

An executed non-passing `RecordValidation` terminally blocks the unit and clears
its consumed selector binding in the same transaction. `ReturnToActive` instead
retains the binding because the same unit and attempt continue. For workspaces
written by the earlier consumer, `Ready` may clear a different unit's stale
binding only for a proposed successor when there is no current unit, both the
selector and checkpoint are Quick, and every selected-unit repository has an
available explicit mapping plus an exact clean Git observation. The selected
unit contract, reconstructed
selector/evidence binding, fully revalidated same-unit non-passing receipt,
unique exact blocker, physical ledger-tail event, and canonical read-only
committed-transition verifier must all authenticate the unchanged terminal
blocked state at the exact live state, unit, and event-ledger paths. Because the
old transition did not bind the receipt and external evidence bytes, the
successor `Ready` transition creates a closed
`terminal_validation_selection_release.v1` proof that hashes those current
bytes, each repository HEAD/tree/branch and empty dirty fingerprint,
blocker/event, selector binding,
and old intent/completion. The new transition intent embeds that proof as a
create-new artifact and the Ready event names it. The dry run reports the proof
identity but creates neither it nor any state change.
Missing, ambiguous, altered, non-terminal, or non-`Ready` cross-unit bindings
continue to reject.

The normal consumer does not execute the producer and does not create evidence.
It changes no source, unit, freeze, repository, device, or remote bytes. Normal
executed lifecycle actions transactionally bind/consume/clear the hash-only
workspace-state selection just as they already change validation state and the
ledger. The selected evidence producer remains responsible for exclusive
`FileMode.CreateNew` output and for emitting the selected schema and live
bindings. A later evidence consumer must validate those bytes separately.

Run the focused damage suite with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Test-NormalValidationSelector.ps1 -SelfTest
```

The suite proves unchanged ordinary behavior without a selector, exact positive
matrix selection without producer execution, pass/fail/return/accept lifecycle
reconstruction, hash-bound terminal recovery, and negative selector/hash/
project/unit/gate/freeze/repository/path-shadow/producer/evidence/action/tier/
omission/replay cases. It is candidate-side
dynamic evidence only. Changes to this consumer, schema, test, or routing still
require the repository's independent base-owned validation-authority review
before commit, adoption, or use against a live workflow.
