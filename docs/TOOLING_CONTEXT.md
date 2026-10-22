# Tooling Context

Fresh opt-in preparation may bind an exact tooling context separately from immutable
product source composition. Source composition v3 carries only the stable
`tooling-context-v1` protocol identifier. The tooling-context artifact binds the
current product source/map/feature projection, the complete tracked executor tree,
the exact clean Git commit/tree/remote, installed router provenance, and passing
owner affected-validation evidence for the same executor revision.

For a new local context, use `New-MorphospaceObservedToolingContext` with the
selected workspace and resolver. `New-MorphospaceToolingContext` constructs and
validates a portable value only; it does not observe a checkout. The observed
producer requires exact clean Git identity and raw closure hashes, then checks
those hashes against the complete pinned Git blob inventory before router and
validation-evidence checks. A clean checkout with converted line endings can
therefore be rejected with the offending path before context staging or router
installation. The producer never normalizes bytes or rewrites an old context.
Run the focused production fixture with
`pwsh -NoProfile -File scripts/Test-ToolingContext.ps1 -SelfTest -ExecutorPreflightOnly`.
The compatibility action catalogue is a finite consumer protocol. It describes the
ordinary lifecycle actions that the tooling revision can interpret; it does not make
a terminal unit's tooling pointer the authority for idle history archive,
historical repreparation, or published-authority adoption. Those operations use their
separate historical owner contracts. Active-unit reads and writes resolve and attest
the current unit's exact context, including the loaded caller modules.

Only `UpgradeToolingContext` may replace the context before Freeze. The unit must
be active in the exact current slot, or Ready in the exact next-ready slot with no
current unit. A Ready upgrade preserves that queue and status; ordinary Claim is
still required before Freeze or BeginValidation. The read-only Ready provenance
reader authenticates the owner-produced Ready transition and each intervening
tooling upgrade, including its product fences and raw CAS. Post-upgrade
`WithdrawReady` authenticates that same Ready-and-upgrade chain and withdraws
against the exact current state/unit CAS, preserving the original Ready receipt
and hashes. Ordinary unupgraded withdrawal retains its existing route. The owner transaction authenticates the historical old context,
the live clean new context, exact typed protocol evidence, and the current effective
product projection. A prior active-envelope extension may have advanced that product
projection through its own authenticated transition; the new context binds the
result, while the old context remains tied to its authenticated origin. The upgrade
changes only the unit pointer, state event tail, immutable request artifact, and
immutable new context artifact. Generic v6 recovery retains byte-level CAS for state,
unit, feature lock, project, and the event prefix.

Resolver files are ignored local bindings under `local/`. They contain absolute
executor and router roots, while portable contexts contain no machine paths. A
resolver supplies location only. It cannot authorize fallback execution, install or
update routers, accept version ranges, use Git ancestry as compatibility, or replace
the exact context evidence. The source-observation receipt explicitly does not claim
independent remote publication authority.

Existing projects without the opt-in fields remain on their existing schema dispatch.
Current021 continues its retirement-first sequence. A later installer Update is a
separate backup-first host action and must Verify against the upgraded context.

A current validating unit may also upgrade immediately after its authenticated
`FreezeCandidate` and `BeginValidation` transitions, before any subsequent
current-unit action or recorded validation. The committed Freeze and Begin
must be contiguous and bind the exact request preimage. The same owner remains
validating; there may be no competing ready unit, blocker or pending publication.
The old context is authenticated historically, the new executor locally, and
compatibility, product/source projection, loaded-module and raw CAS guards remain
mandatory. The action emits a validating-to-validating receipt using the existing
upgrade request and typed ledger transition.

This upgrade preserves the original frozen marker and receipt bytes. Frozen
reads authenticate the complete typed continuation to the physical live state,
verify that the upgrade changed only the tooling pointer of the original
validating unit, then reconstruct the original Freeze projection for its exact
unit/state hash checks. They do not remove tooling from the hash or rewrite the
marker. Historical upgrade verification uses that committed prefix even after
later instruction completion, fresh validation and acceptance. No earlier pass
is inherited: validation and acceptance still run under the new selected context.
Run this public host fixture with
`pwsh -NoProfile -File scripts/Test-ToolingContext.ps1 -SelfTest -Scenario validating-upgrade`.

An authenticated failed frozen unit may deliberately upgrade tooling for its
nonaccepting retirement. This route requires the exact active/current unit,
a retained failing checkpoint, no remaining blockers or ready unit, and the
original committed Freeze, BeginValidation, fail, Resume and ResolveBlocker
chain. It preserves the original freeze, failure receipt, product projection
and accepted checkpoint. The ordinary context, compatibility, owner-validation,
raw CAS, recovery and historical guards still apply; no validation, acceptance
or runtime effect is granted.