# Development Envelope Preparation

`PrepareDevelopmentEnvelope` is the only owner action that prepares an idle,
previously accepted project for a later development-unit admission. It is not
an admission, Claim, source mutation, build, device operation, or publication
action.

The action accepts a typed preparation input and exact preimages for the
project, idle workspace state, feature lock, repository map, accepted
predecessor unit, and event ledger. It may atomically add bounded project
repositories and roots, zero or more project-generic feature bindings, the
corresponding effect/permission ceiling, and the build/device envelope. Every
existing feature remains byte-identical. Every added feature ID must be added
to both project composition and the feature lock, selected, default-disabled,
and runtime-input activated. The declared permission ceiling must equal both
the project and lock unions; `none` is the sole sentinel for an empty union.
Preparation records a preparation-owned source-composition lock from clean
repository-map observations without requiring an iteration-unit document for
the future unit.

An ordinary preparation may also add roots to an existing repository. Every
other field of that repository record and every existing root remain unchanged.
Each added root must exactly match a reviewed `owner_repositories.source_roots`
entry, use a canonical portable path, and neither duplicate nor overlap another
root. The preparation still observes the repository's exact clean source
identity. An ancestor directory is not an alternative to the reviewed root.
Historical repreparation retains its original, narrower repository contract.

Both the current and target feature lock must carry the deterministic
fingerprint obtained by setting `lock_fingerprint` to 64 zeroes and hashing the
canonical compact UTF-8 JSON projection. The current workspace module registry must
match the current lock and selected project modules. Whenever the lock changes,
preparation derives and CAS-installs the target registry from the target lock
revision/fingerprint and selected modules. Prepared build profiles must be
registered in the target project; existing validation profiles are immutable,
and every new registration must be named by the declared build-profile ceiling.

An optional `schema_pin_revision` permits the same owner transaction to advance
the project, feature-lock, and workspace-state `$schema` pins. The three live
documents must already share one exact pinned Work Environment revision, the
field must name one different lowercase 40-hex revision, and the authored
project and feature-lock URLs must be the canonical URLs for that exact target;
the workspace-state URL is derived from the same value. The value is supplied
by the independently reviewed caller rather than discovered from the candidate
checkout or its `HEAD`. Preparation validates and CAS-commits the binding, but
does not approve or adopt that Work Environment revision. Without the optional
field, every schema pin remains byte-identical.

One finite preimage repair is recognized for a project pinned to Work
Environment revision `f45a7500d0a68b5cea0d910b26010c10ba42705c`: the malformed
`public_boundary.mode` value `public-source-private-planning` may be projected
to the schema-defined `mixed` value. The owner validates a clone of the complete
current project after that single substitution and accepts the projection only
when the clone satisfies the current closed project schema. The target must
contain `mixed` itself, and the private overlay and ordered prohibited-evidence
list remain unchanged. The transaction binds the unmodified current document
and its preimage hash; the projection is used only to validate this repair and
compare the target. No other invalid project or boundary value is accepted.

The project identity and accepted predecessor bytes remain unchanged. The
target state remains idle (`current_unit` and `next_ready_unit` are null); no
source, Git remote, build, APK, or device mutation is performed. A preparation
receipt explicitly proves neither schema-revision approval nor any later
lifecycle authority.

An idle project may retain immutable `active` or `validating` documents from
earlier superseded units. Preparation uses the shared
[current-work boundary](CURRENT_WORK_VALIDATION.md): authenticate the accepted
checkpoint and current suffix, then recognize canonical retirement chains in
the sealed prefix. Do not require old edges to acquire newer proof versions or
skill declarations. Preserve historical bytes and audit findings separately.
Current or queued work, blockers, pending publication, ambiguous/orphaned chains,
damaged acceptance evidence, stale preimages, and incomplete current transactions
remain admission failures. Explicit prerequisites retain their own evidence.

After that authenticated idle boundary, a canonical same-project `proposed`
unit may remain as an inert draft when it has no admission, preparation, freeze,
or inherited-candidate binding and no typed incoming unit-identity or unit-path
reference. Preparation checks the retained units and events, project/lock/state,
canonical receipt and transaction records, and declared archive-root metadata.
References include prerequisites and pending or orphaned transaction bindings;
prose mentions do not establish authority. The check does not traverse local
evidence payloads or archive objects. Unreadable control records or ambiguous
identities cannot prove absence. The existing prerequisite checks still apply
to the draft itself.

This read-only classification preserves the draft byte-for-byte. It grants no
admission, retirement, acceptance, or validation credit and needs no lifecycle
transaction of its own. Fresh preparation retains the accepted checkpoint and
source-lock rules; later admission still requires its ordinary fresh, absent
unit identity. An admitted or referenced proposal still follows its existing
owner route, including `RetireProposed` where applicable.

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

When source revisions or scope must change, ordinary preparation may continue
from idle history containing authenticated retired proposals. The current-work
reader proves each completed `RetireProposed` transition, including an exact
admission timestamp recovery when present. It does not treat an arbitrary
superseded unit as accepted history. The new preparation binds current source
identities and ceilings; old admissions, recoveries, and retirements remain
immutable and confer no validation credit.

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

After an exact `RetireProposed` transaction, a preparation affected by the
lock-fingerprint/module-registry defect is not reusable. The narrow
`ReprepareRetiredDevelopmentEnvelope` action authenticates the contiguous old
preparation, admission, and retirement suffix and a distinct absent replacement
identity. Its project, feature-lock, and raw repository-map preimages must equal
the original preparation intent targets. The repository-map path is derived
from the original preparation's equal pre/target bindings, must also equal the
predecessor admission and recovery path/hash binding, and is resolved beneath
the workspace with the ordinary confinement and reparse checks; it is not
restricted to a root filename. Its idle state preimage must equal the retirement
intent target. Resumed intent/completion timestamps must use the
strict seven-digit UTC form and the completion cannot predate the intent. The
action then atomically installs a corrected additive project/lock/state
triple plus a fresh preparation receipt and source-composition v2 lock. It
preserves the retired unit and all older artifacts byte-for-byte. Its source
observation accepts only exact, hash-enumerated workflow-owned dirt in planning
repositories; source repositories remain clean. The action grants no Ready,
Claim, source-write, device, remote, or publication authority, and the named
replacement still requires ordinary admission under its fresh unit identity.
