# Raw-Bound Artifact Transition

Transition-ledger intent v5 is the closed owner transaction for a planning
event that must preserve the exact raw pre-unit bytes, leave the canonical unit
document unchanged, advance only the workspace event tail, and create one or
two immutable event artifacts. It is distinct from v4: v4 requires one or two
`feature.lock.json`/`project.spec.json` projections, while v5 permits no
additional projection and no supersession.

The producer binds the canonical unit path and lowercase raw SHA-256 in
`pre_unit_raw`. Its target unit hash must equal the pre-unit canonical hash.
The target state may differ only by `last_event_id`. Artifact paths are
canonical, unique, ordinal sorted, embedded as exact base64/hash pairs, and
equal the event's ordered receipt paths. Completion and repair revalidate the
raw bytes until the unchanged target unit is present, then continue from the
authenticated target while preserving idempotence.

Committed-transition authority and terminal blocked-history validation both
revalidate the closed v5 root, raw binding, unchanged unit, exact state/event
chain, live artifact bytes, and completion reference. V5 cannot replace the
receipt-bound proposed-unit retirement v1 route, carry a v2 supersession, or
smuggle an empty/no-op v3/v4 projection.

Run these proportional checks for contract changes:

- `scripts/Test-TransitionLedger.ps1`
- `scripts/Test-OwnershipAuthority.ps1`
- `scripts/Test-BlockedSupersessionTerminalValidation.ps1`
- `scripts/Test-CorrectActiveUnitContract.ps1 -SelfTest`
