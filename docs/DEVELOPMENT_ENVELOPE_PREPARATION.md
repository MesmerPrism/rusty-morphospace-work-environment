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
agent continues through ordinary Ready/Inspect/Claim and Freeze.
