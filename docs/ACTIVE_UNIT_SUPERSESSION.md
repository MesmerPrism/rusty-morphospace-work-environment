# Active-Unit Supersession And Blocked-Successor Recovery

Use these owner actions when immutable later work must replace stale lifecycle
authority. They preserve old units and evidence; they do not infer acceptance.

## Active successor

`SupersedeActive` consumes one reviewed `active_unit_supersession.v1` request.
The request binds the exact project, compact state, event ledger, repository
map, old active unit, proposed replacement, and complete repository overlay.
Every repository authorized by the old unit is observed. Each dirty path must
belong to exactly one scope: the replacement or a named companion proposal.
Unselected repositories must be clean. Rename endpoints must have one owner.

Only the replacement becomes current and `active`. Companion units are exact
overlay-only bindings: they stay byte-identical `proposed` units and gain no
Ready, Claim, validation, acceptance, publication, or current-unit authority.
The old unit remains byte-identical historical evidence.

Execution requires the reviewed request SHA-256. A fresh transaction creates
one exact automation receipt and one canonical supersession event. If an exact
intent already exists, authenticate its request, paths, endpoints, preimages,
target transform, artifact, and repository observation before completing it
with ledger repair. Orphaned or conflicting intent/completion/event evidence
fails closed. Completed replay returns the original transaction-owned receipt.

## Terminal blocked successor

Use `PrepareBlockedSuccessor` only after a candidate-frozen unit has terminated
through an authenticated Standard `blocked` validation transaction and the
evidenced repair path is inside the existing project and agent envelope but
outside the terminal unit's write scope. Preparation preserves the terminal
unit and installs exactly two transaction artifacts: a preparation receipt and
a clean exact source-composition lock.

`AdmitDevelopmentUnit` binds those artifacts and admits only the single
evidenced repair path as a new `proposed` unit. The blocked predecessor is not
an ordinary accepted prerequisite. During the successor's ordinary `Ready`,
release-v2 may clear only the exact stale selector associated with the terminal
unit. It records `selector_evidence_verified=false` and
`selector_evidence_reused=false`.

Interrupted preparation resumes only from its exact authenticated ledger
intent; completed replay returns the original result. No step here resumes or
edits the terminal unit, mutates product source, runs validation, builds,
touches a device, accepts a unit, or publishes anything.

## Validation

Run the focused ActiveUnitSupersession and BlockedSuccessorPreparation owner
self-tests, then the affected-validation selector/topology/reuse contracts and
only the directly dependent DevelopmentUnitAdmission,
DevelopmentEnvelopePreparation, NormalValidationSelector, and
WorkUnitAutomation checks. Reuse unrelated exact per-check receipts; do not
fall back to a cumulative Deep aggregate solely because these paths changed.
