# Correcting resolved-blocker evidence

`CorrectResolvedBlockerEvidence` is an additive, product-neutral correction
route for a blocker that is already absent. It does not replace or edit the
historical `ResolveBlocker` event, receipt, intent, or completion. It records
that the retained historical resolution evidence remains part of the audit
trail while its broader complete-resolution claim is superseded by fresh,
hash-bound passing evidence.

The strict
`rusty.morphospace.workflow.blocker_resolution_correction_receipt.v1`
binds one exact historical blocker-resolved event and its original receipt,
intent, and completion paths and SHA-256 values. Validation checks the original
receipt schema and identity, the event's single receipt reference, the
completion-to-intent file hash, final state/unit identities, and the
intent-owned original artifact. Historical external source hashes are retained
evidence and are not required to equal current working-copy bytes.

When retained current-unit prose needs a narrower current interpretation, the
receipt also carries a product-neutral `authority_clarification`. It binds the
exact immutable unit path and file SHA-256, resolves one JSON pointer to exact
retained text, verifies that text's UTF-8 SHA-256, and records
`superseded-for-current-interpretation` plus typed schema/private-semantics
authority relations. The unit remains byte-for-byte unchanged. Missing,
drifting, or pointer-substituted clarification evidence rejects, and the
installed correction makes the clarification part of replay validation.

Fresh evidence is workspace-local. `repository_heads` and
`repository_sources` must each exactly cover the supplied repository map.
Every source is a normalized forward-slash repository-relative regular file;
absolute, drive-qualified, UNC, empty, dot, parent, trailing-separator,
duplicate, case-fold duplicate, escaping, symlink, and reparse paths reject.
Heads, branches, evidence, and source bytes are checked initially, and heads,
branches, and sources are checked again immediately before the transition.

The current unit must be active, the target blocker must be absent, and
`preserve_blocker_ids` must exactly enumerate all live blockers. Execution
requires a new workspace-local top-level receipt output. Under the transition
ledger mutex, state, unit, and event-tail CAS precede every projection or
artifact write. The transaction changes only `last_event_id`, appends one
generic `state-transition` event named
`<unit>-blocker-resolution-corrected-<sequence>`, and installs the exact input
receipt as a transaction-owned artifact. Pending publication, validation
checkpoint, acceptance pointer, plan revision, current unit, unit bytes, and
the complete blocker set remain unchanged.

Historical correction events are themselves fail-closed audit dependencies.
Missing, malformed, schema-invalid, identity-inconsistent, hash-mismatched, or
transaction-chain-damaged correction evidence blocks a later correction.
Receipt identity and canonical receipt hash are stable replay keys, independent
of caller input and output paths.
