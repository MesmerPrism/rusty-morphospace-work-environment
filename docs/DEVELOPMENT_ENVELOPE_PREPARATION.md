# Development Envelope Preparation

`PrepareDevelopmentEnvelope` is the only owner action that prepares an idle,
previously accepted project for a later development-unit admission. It is not
an admission, Claim, source mutation, build, device operation, or publication
action.

The action accepts a typed preparation input and exact preimages for the
project, idle workspace state, feature lock, repository map, accepted
predecessor unit, and event ledger. It may atomically add bounded project
repositories and roots, the corresponding feature/effect/permission ceiling,
and the build/device envelope. It resolves the exact feature lock and records
a preparation-owned source-composition lock from clean repository-map
observations without requiring an iteration-unit document for the future unit.

The project identity and accepted predecessor bytes remain unchanged. The
target state remains idle (`current_unit` and `next_ready_unit` are null); no
source, Git remote, build, APK, or device mutation is performed.

Preparation uses its own v1 intent, completion, receipt, and event. Each binds
the complete multi-document CAS set. A matching interrupted transaction may
resume; a changed input, preimage, artifact, event prefix, or target rejects.

The v1 preparation receipt and intent bind the source-composition document by
canonical JSON SHA-256, because that identity remains stable across harmless
JSON serialization differences. The transaction artifact also retains the
exact authored bytes. These are distinct from the raw-file SHA-256 that a later
admission supplies for its live workspace preimage; neither hash domain may be
substituted for the other.

`AdmitDevelopmentUnit` subsequently binds this exact receipt and its generated
source-composition lock. It may only prove that the authored future unit is a
subset of the already prepared envelope; it must not discover or project new
project, feature, effect, permission, build, device, repository, or root
authority.

An ordinary preparation publishes one result and later ordinary admission binds
that result. Exact replay revalidates the same durable result; an interrupted
owner transaction resumes only its own intent/completion path. A conflicting
replay, stale target, changed source lock, or changed repository-role set fails
closed for independent owner rescue, not an agent-made rewrite. Once bound, the
agent continues through ordinary Ready/Inspect/Claim and Freeze. If that first
immutable proposal is rejected before Ready, one completed `RetireProposed`
transaction may name a separately authored replacement. The replacement may
reuse this preparation only when the live ledger has the exact contiguous
preparation, first-admission, and retirement suffix, the state remains idle,
and both completed transition chains plus the original preparation/source
identity validate. This is not a general stale-state waiver: intervening or
repeated lifecycle transitions require a new owner decision. A durable first
admission intent consumes ordinary use even if the state and event ledger are
jointly rolled back, and replacement recovery/replay continues to revalidate
the exact predecessor chain after its own intent exists.

For the replacement's later candidate Freeze, the preparation binding remains
valid only through the exact contiguous owner lifecycle: replacement Admission,
ordinary Ready, then ordinary Claim. Freeze authenticates each committed
intent/completion/event and their state/unit hash chain through the exact live
active projection. It does not accept an arbitrary later state merely because
the replacement admission was once valid; any intervening event, damaged
transaction, different unit, adoption-bearing Claim, or non-active tail fails
closed.

The preparation-owned source composition is a project-envelope lock, not a
writable-scope declaration. It may contain read-only dependencies in addition
to the repositories the later unit is permitted to change. Freeze keeps the
unit's final-repository and changed-path sets exactly equal to that writable
scope, while requiring every writable repository to be present in the source
composition. Every source-composition repository must still resolve through
the authenticated repository map with the same role. Read-only dependencies
must remain at their exact locked commit/tree. A writable candidate may advance
from its locked baseline only through proven Git ancestry, and its live
commit/tree must equal the final identity recorded by Freeze. The committed
baseline-to-candidate path delta must remain inside both the candidate closure
and active write scope. Read-only source dependencies remain tracked-clean;
workflow-owned planning dirt is not mistaken for source input. Neither
dependency cleanliness nor observation is promoted into mutation authority.
