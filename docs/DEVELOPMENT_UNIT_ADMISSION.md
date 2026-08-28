# Development-Unit Admission and Candidate Freeze

`PrepareDevelopmentEnvelope` is the only owner action that changes an idle
existing project's future development envelope. It atomically advances only
the additive project/repository-root and feature/effect/permission/build/device
ceilings, emits its own typed intent/completion/receipt/event, and creates a
preparation-owned source-composition lock from the repository map without a
future unit document. It preserves accepted history and an idle state. See
[Development Envelope Preparation](DEVELOPMENT_ENVELOPE_PREPARATION.md).

`AdmitDevelopmentUnit` is the only owner action that begins that later feature.
It must bind the exact preparation receipt and preparation-owned source lock,
then accepts a bounded `agent_scope_assessment.v1`, an
exact proposed unit, and CAS bindings for project, feature lock, source
composition, repository map, state, and event ledger. Admission binds the
prepared project and feature lock as immutable preimages: it never accepts a
projection of either document and may not rewrite project, feature, root,
effect, permission, build, or device authority.
For the prepared source composition, `preparation.source_composition_sha256`
and `expected.source_composition_sha256` are raw-file SHA-256 bindings to the
exact live workspace bytes. The preparation receipt and intent artifact retain
their canonical-JSON SHA-256 identity separately. Admission must verify both
domains plus the intent's exact base64 bytes; canonical and raw hashes are not
interchangeable.
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

If Ready exposes a defect in the immutable admitted contract itself,
`RetireProposed` is the only owner route that can close that identity before
Claim. It requires `status=proposed`, an idle project with no current or
next-ready unit, the exact admission event as the ledger tail, and the complete
committed admission receipt/intent/completion chain. Its dry run returns the
canonical state/unit hashes, raw unit-byte hash, ledger hash/length/tail,
admission artifact hashes, a distinct absent replacement identity, and one
binding hash. Execution must replay every identity, writes its receipt through
the transition ledger, changes only the old unit to `superseded`, and appends
one retirement event. The original admission bytes and event remain immutable;
the replacement is separately authored and admitted under a new unit ID.
`RetireProposed` cannot withdraw a Ready unit, retire an active unit, repair a
candidate in place, create the replacement, or authorize source/build/device
mutation.

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

Admission consumes the canonical preparation result once per exact unit input.
Exact replay and owner recovery revalidate that result; stale or conflicting
evidence stops for independent rescue. A successful admission resumes the
ordinary agent lifecycle rather than creating a preparation-only route.
