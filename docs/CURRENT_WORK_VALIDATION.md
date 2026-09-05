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

Preparation uses this same boundary automatically. Archive checkpoint admission
also recognizes retired lifecycle identities while copying the original bytes.
An interrupted current operation still uses its existing exact recovery action.
Historical classification is read-only and introduces no receipt schema or
repair event.

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

External planning repositories remain the sole current authority after a
completed materialization/adoption. Embedded source-repository history is a
retained snapshot. Route through the project's existing local repository map;
do not put machine paths into portable instructions or restore the embedded
snapshot as current state.
