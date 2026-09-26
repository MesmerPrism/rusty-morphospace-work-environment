# Active development-envelope extension

`ExtendActiveDevelopmentEnvelope` extends one exact admitted feature unit while
it remains active. It is the owner route for a newly discovered code dependency
or exact owner source root that is necessary to complete the unchanged objective
and acceptance criteria. It does not retire or re-admit the unit.

The action requires the authenticated original preparation and admission, the
ordinary Ready and Claim transitions, and every later committed envelope
extension. The current project, feature lock, state, unit, event prefix, source
composition, and repository map must equal that chain's effective endpoint.
Caller-supplied provenance, a copied workspace, or a self-consistent alternate
map does not grant authority.

## Closed additive change

The owner-reviewed v1 request carries complete target project and feature-lock
documents, the complete target agent scope assessment, and the complete target
writable and read-only repository closures. It separately enumerates every
addition category, but only repository and owner-root additions may be
non-empty. Feature, module, authority, effect, permission, validation,
rollback, build, and device additions must be empty; their admitted ceilings
remain exact. The computed difference must equal those lists exactly.

Existing repository records preserve identity, role, path, and existing roots.
Existing feature, module, authority, validation-profile, and acceptance-profile
rows remain byte-equivalent. The project and feature lock each advance one
revision. The workspace advances `plan_revision` by one and derives its module
registry from the target lock and selected modules. Existing unit identity,
role, objective, acceptance criteria, non-scope, prerequisites, instructions,
validation policy, commit policy, push checkpoint, and public/private boundary
remain unchanged.

New roots must be canonical and exact owner-reviewed roots. The project,
assessment, and unit writable/read-only closures must agree. A repository cannot
be both writable and read-only. Every selected feature retains disabled-default,
runtime-input activation and a closed dependency, module, authority, effect,
validation, and rollback closure. Existing denials stay effective.

The action is forbidden unless the exact current unit is an unfrozen `active`
feature unit with no queued unit, blocker, current validation checkpoint, pending push
or publication bundle, or incomplete transaction. It cannot follow candidate
Freeze.

A retained passing checkpoint may remain only when it equals the state's
`last_accepted_receipt` and the exact checkpoint sealed by one authenticated
accepted predecessor transaction. The predecessor unit and acceptance evidence
must remain unchanged. Current-unit, unaccepted, mismatched, malformed or damaged
checkpoints fail closed. This preserves prior acceptance; it grants no validation
credit to the active unit. Recovery and later read-only replay verify the same
proof against the captured pre-extension ledger prefix, without requiring that
extension to remain the live ledger tail.

## Repository-map ownership

The ignored local repository map remains caller-maintained input. The action
never writes it. A roots-only extension reuses the current effective map without
changing its bytes. Adding a repository requires a distinct new workspace-local
map. Every previous row, including local path, role, and aliases, must remain
canonical-JSON-equal; the new rows must equal the explicit repository additions.

The original admission map path and raw hash remain immutable. The request also
binds the current effective map and the proposed effective map by relative path
and raw SHA-256. The derivative source artifact binds the same identities.
Recovery rechecks the maps before any transaction write.

## Source lineage and working copies

The action creates
`active_development_envelope_source_composition.v1` as a new derivative
artifact. Its immutable parent may be preparation source composition v1, v2, or
v3, or a prior active-envelope derivative. It binds the original preparation
source as a separate immutable ancestor. Existing source locks are never
rewritten.

Each repository row preserves its original baseline commit and tree, names its
parent effective commit and tree, and records its new effective commit and tree.
Read-only dependencies must remain clean at the exact parent identity. New
repositories must be clean. An existing writable repository may advance only
through Git ancestry, and every committed or uncommitted changed path since the
parent identity must remain within the pre-extension active write scope. Such
worktree dirt is recorded as observation; it grants no additional write scope
and is not incorporated into a commit identity.

The derivative fingerprint is the canonical JSON SHA-256 of the complete
document with only `fingerprint` set to 64 zeroes. Parent and original source
bindings carry raw SHA-256, canonical JSON SHA-256, schema, lock id, and
fingerprint.

## Transaction and recovery

Execute requires the exact raw SHA-256 returned for the reviewed request by dry
run. Transition-ledger v6 binds canonical and raw preimages for the state, unit,
project, and feature lock, plus the exact event-ledger hash, length, and tail.
Its two event artifacts are the exact reviewed request and the generated
derivative source composition. The target state, unit, project, and feature lock
commit with one event and completion record.

The narrow
`Assert-MorphospaceActiveEnvelopeExtensionRecoveryBindings` guard authenticates
the two artifact schemas and bytes, request identities, all v6 projections,
original and parent source locks, and original/current/target repository maps.
The generic transaction recovery dispatcher runs it before installing an
artifact, projection, event, or completion. It has no caller proof override or
skip mode. Exact replay is idempotent; changed input, lineage, map, source,
projection, or CAS evidence fails closed.

The extension proves no Claim, Freeze, validation, acceptance, publication,
Git mutation, build, device action, schema-revision adoption, or changed
objective authority. Later Amendment, Freeze, retirement, current-work reading,
and continuation must authenticate the effective extension chain rather than
comparing against the original preparation endpoint alone.
