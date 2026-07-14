# Advanced Validation Authority

This is the detailed, fail-closed path for receipt-security corrective units.
Ordinary application units should use the standard project workflow and should
not copy this machinery merely because it exists.

## Admission And Ownership

A receipt-security unit must not use a hand-authored
`validation_receipt.v1`. It requires a registry-selected tracked owner
validator, a fresh content/ownership observation, typed per-criterion owner
evidence, and a derived `validation_receipt.v2`. Validator execution happens
from a closed input room; registry byte, closure, output-limit, mutation, and
no-device policies are rechecked before the receipt is accepted.

A pre-existing dirty instruction file is baseline input, never current-unit
attribution. If the unit adds routing to that file, declare the exact shared
integration instead of absorbing prior work.

## Proportional Git Observation

When a mapped repository has a large pre-existing dirty overlay, capture tree,
index, name-status, binary diff, and zero-context hunk evidence in bounded
aggregate Git calls. Bind each path to exact base/head/index/worktree content,
lease the observed worktree bytes, then repeat aggregate HEAD, status,
hidden-index, diff, and instruction boundaries. Per-path Git subprocess loops
add no authority beyond leased bytes plus aggregate boundaries and can multiply
one check into thousands of process launches.

## Nonce-Bound Execution

For this path, `RecordValidation -Execute` invokes the migrated hash-pinned
authority runner. It supplies a fresh 32-byte execution nonce and accepts the
v2 receipt only when that exact nonce is bound to the execution record.
Supplying a prewritten receipt, alternate runner path, or caller-selected runner
switch is rejected.

A closed room may carry explicitly listed historical Git blobs when a static
gate verifies their object IDs. Copy them into a local sealed object store and
fingerprint them separately from the live repository.

Registry, protocol, ownership, action, evidence, and execution documents remain
canonical schema objects. The runner carries locations separately, verifies
each in-memory document against its bound path, and emits typed
path/schema/SHA references; it never injects internal path metadata into a
canonical object.

## Stages

1. Validate portable and project workspace contracts without mutation.
2. Seal the exact runner release and every repository, registry, protocol,
   validator, and dependency reference into a content-addressed capsule.
3. Materialize or reuse the capsule only after its manifest and clean-room
   fingerprint match, then run a fresh child-host capability probe.
4. Run the sealed validator in admission-only mode and publish a v2 preflight
   bound to project, unit, attempt, runner, capsule, host, clean room, unit
   contract, command identities, and acceptance bindings. It must not execute
   acceptance commands or emit owner-validation evidence.
5. Invoke `RecordValidation` with a fresh execution nonce, run the full owner
   validator exactly once, and publish no-overwrite evidence and receipt.
6. Revalidate every artifact, current observation, and transition at
   acceptance.

Preflight proves admission, not owner behavior. Only the nonce-bound Validate
branch executes acceptance commands. Every stage writes a typed bounded result
with exact input identities, elapsed time, stream hashes/references, status,
failure code, and next action before temporary cleanup. Failed attempts remain
immutable evidence.

## Reuse And Identity

Content-addressed reuse is an optimization. It requires the same capsule and
runner release plus fresh host and clean-room checks. Partial publication,
tamper, stale host, changed dependency, materializer drift, or fingerprint
mismatch rejects the cache. Cleanup is confined to the owned temporary capsule
directory.

A corrective migration may be selected by immutable project/unit identity as
well as descriptive tags. Removing a tag must not downgrade a registered unit
to the generic v1 path.

Run the Deep work-environment tier after changing this surface.
