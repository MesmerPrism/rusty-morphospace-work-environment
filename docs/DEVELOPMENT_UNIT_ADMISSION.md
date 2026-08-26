# Development-Unit Admission and Candidate Freeze

`AdmitDevelopmentUnit` is the only owner action that begins a later feature in
an idle existing project. It accepts a bounded `agent_scope_assessment.v1`, an
exact proposed unit, and CAS bindings for project, feature lock, source
composition, repository map, state, and event ledger. Admission binds the
existing project and feature lock as immutable preimages: it never accepts a
projection of either document and may not rewrite project or feature authority.
The transaction creates the unit and receipt together through the standard
typed transition-ledger intent/completion shape; its durable intent may be
completed after an interruption. Exact replays are idempotent, while a reused
unit identity with different input is rejected.

Admission is deliberately not Claim. The admitted unit remains `proposed` and
must pass the ordinary `Ready`, `Inspect`, and `Claim` routes. The assessment
declares repositories and roots, public/private boundary, feature/effect/
permission ceilings, build and device envelope, non-scope, prerequisites,
validation class, and evidence/cleanup expectations. It never substitutes a
complete changed-file list for bounded exploration.

An admitted active unit may use `AmendActiveWriteScope` only for a discovered,
tracked path inside its original repository/root envelope. The amendment binds
semantic rationale, source-composition identity, and ownership proof; it cannot
widen the project or agent envelope.

Before `BeginValidation`, an admitted unit must use `FreezeCandidate`. The
freeze receipt records exact repository commits/trees, changed paths and
cleanliness policy, instructions, feature lock, effects/permissions/device use,
test matrix, cleanup/evidence roots, and source-composition closure. Each
final repository must resolve through the bound repository map and exact source
composition lock; duplicate IDs, substituted commit/tree identities, dirty
clean-only worktrees, and changed paths outside the declared closure reject.
The freeze transition binds the exact pre-state and ledger prefix plus its
target state/unit, event, intent, and completion; BeginValidation rechecks that
entire transition before it consumes the marker. Repeating
the exact freeze is idempotent; a different freeze is rejected. Units that
predate the admission marker retain their existing historical compatibility
rules and are not silently migrated.
