# Current work and historical auditing

Ordinary project continuation uses `Test-WorkflowContracts.ps1` with
`-WorkspaceRoot`, `-RepositoryMapPath`, `-CurrentWorkOnly`, and
`-SkipOwnerSelfTests` when consuming an unchanged adopted work-environment.
Register this exact command in the current project's validation profile.
`CurrentWorkOnly` selects the history boundary; `SkipOwnerSelfTests` only avoids
rerunning the shared owner's isolated test suite. Neither switch grants
validation, acceptance, publication, or device evidence by itself.

The boundary is the unique committed acceptance transaction named by compact
state. Its retained unit and ledger prefix must still authenticate. Canonical,
unambiguous supersession chains ending in accepted history before that boundary
retire old active/validating unit files without rewriting them. Their old skill
lists, scopes, and pre-protocol transaction shapes are historical audit concerns,
not prerequisites for unrelated new work. No per-unit compatibility receipt is
required merely to continue from this boundary.

Current ownership, queued work, blockers, pending publication, source identities,
instruction requirements, scope intersections, compare-and-swap preimages, and
incomplete current transactions remain strict. Transactions after the boundary
must authenticate and derive live state. Explicit prerequisites must retain
their own accepted evidence; historical classification grants no validation
credit. An orphaned, ambiguous, resurrected, or unaccepted dependency cannot be
hidden by calling it history. A workspace without an authenticated acceptance
gets no historical exemption.

One exact owner-Git accepted checkpoint predates the ledger `expected` and
`artifacts` bindings. The current-work reader recognizes only that finite
checkpoint tuple, bound by an opaque pinned consumer commit and a closed digest
over its intent, completion, event-ledger prefix, unit, and validation receipt.
It also requires the exact pinned producer commit and source blobs,
producer-pinned state and unit schemas, strict producer-schema validation, the
complete record hash chain, identical tuple blobs at the pinned consumer commit,
and byte-identical live owner-Git copies. Producer-era shape or schema identity
alone grants no compatibility. The old shape remains forbidden for every other
checkpoint and every current suffix transition. This classification neither
reconstructs missing evidence nor upgrades the checkpoint to current validation
policy.

An explicit prerequisite may continue to name that same finite checkpoint
after a later ordinary acceptance moves the current boundary forward. The
reader reuses the closed checkpoint proof only when its terminal event is at or
before the authenticated current boundary. This preserves an already accepted
dependency; it does not authorize another old-shape record, reinterpret a
suffix transition, or grant fresh validation credit.

Current suffix authentication also follows two existing owner-produced
transaction identities that are not derived directly from their event ids. A
development-envelope repreparation resolves only through its exact ordered
repreparation and preparation receipt references, then authenticates the
producer transaction, ledger predecessor, projections, artifacts, preserved
evidence, and completion. An admission-completion timestamp recovery resolves
only through its exact canonical recovery receipt. It authenticates the
original admission, malformed completion, preparation and repreparation chain,
raw evidence, derived correction row, recovery transaction, and subsequent live
state derivation. The malformed completion remains byte-exact historical
evidence.

The public current-work validator uses that authenticated producer projection
when later owner transactions retire the proposal or prepare another envelope.
It must not require the recovered proposal to remain live or the recovery to
remain the ledger tail. Recovery execution retains its exact live preconditions;
the read-only projection applies only after the current-work chain authenticates.

An exact owner-produced proposed-unit retirement is reported separately as
`retired-proposed`, whether it follows the current accepted boundary or a later
accepted checkpoint has sealed it into that boundary's prefix. It may allow a later idle
preparation to exclude that superseded proposal from current ownership. It does
not make the proposal accepted, add it to accepted history, satisfy a
prerequisite, or grant validation credit; resurrection and live-state checks
remain strict.

A preserved predecessor can retain an obsolete source-scope contradiction
after a supported handoff. After an exact owner-produced `SupersedeActive` replaces an
immutable active unit, the old unit's declaration of the same
repository as both writable and read-only may be ignored while the replacement
is current and in flight. The current-work reader authenticates the committed
transaction, its installed automation receipt and original SHA-bound request,
the byte-exact old unit, the proposed-to-active replacement preimage, and the
unique chain into the current unit. The old endpoint must be neither current,
next-ready, nor a prerequisite. This is only a read-only classification of that
one obsolete scope declaration. It does not make the old unit accepted or
historical, grant validation credit, defer any other structural error, or relax
the replacement unit's current scope checks.

Preparation uses this same boundary automatically. Archive checkpoint admission
also recognizes retired lifecycle identities while copying the original bytes.
An interrupted current operation still uses its existing exact recovery action.
Historical classification is read-only and introduces no receipt schema or
repair event.

Current-work retirement history accepts exactly the closed direct-owner
`proposed_unit_retirement_receipt.v1` and the complete legacy
`work_unit_automation_receipt.v1` compatibility envelope. Both must bind the
same committed retirement semantics and preserved admission evidence. The
direct format additionally binds its transaction ID, paths, event, and every
state/unit/event-ledger CAS identity to the transition intent. Format dispatch
does not convert receipts or rewrite accepted historical bytes.

Lock validation uses one shared predicate for the two existing owner formats:
canonical JSON and the original resolver's ordered compressed JSON. Both hash
the complete document with only `lock_fingerprint` zeroed. The resolver now emits
canonical fingerprints; existing stored fingerprints and receipt bindings stay
unchanged. This fixes producer/validator disagreement without declaring a valid
old lock damaged or requiring a recovery transaction.

For an explicit historical audit or migration, omit `-CurrentWorkOnly`.
Historical adoption, compatibility, reconstruction, and debt-baseline recipes
remain available for that purpose. Do not initiate them just because an old
unit lacks a rule introduced after its work ended. Report audit findings with
their affected history and whether any current consumer actually depends on it.
Do not combine a current-work result with full-history debt evidence.

Changes to the shared workflow owner still require its own tests and final CI
matrix. Run focused checks and one bounded real-consumer preflight during
development, obtain independent review, then freeze one candidate for the final
matrix. An unchanged consumer must not rerun those owner self-tests at each
product checkpoint. Current-work success does not claim the full historical
audit passed.

Preparation and admission-consumer discovery use the same accepted-checkpoint
proof as current-work history. This permits only that exact pinned old-shape
accepted predecessor; contemporary accepted checkpoints still use the strict
ledger validator. A prerequisite can use the finite proof only at or before the
authenticated current boundary. Current suffix transitions and general ledger
validation do not gain a compatibility route.

External planning repositories remain the sole current authority after a
completed materialization/adoption. Embedded source-repository history is a
retained snapshot. Route through the project's existing local repository map;
do not put machine paths into portable instructions or restore the embedded
snapshot as current state.
