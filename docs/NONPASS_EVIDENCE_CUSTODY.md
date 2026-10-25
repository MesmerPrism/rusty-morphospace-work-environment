# NONPASS evidence custody and corrective retry

A failed frozen validation must remain readable after its source or
Git index changes. New `validation_receipt.v1` results `fail`, `partial` and
`blocked` therefore retain the explicit top-level opaque artifact bytes in an
owned, ignored and untracked receipt evidence directory. The receipt references
those snapshots. Its additional hashed `nonpass-evidence-custody` manifest binds
the original locators, artifact identities, snapshot paths, lengths and hashes.
It supplies no passing validation or acceptance credit.

This applies to source-locked frozen units in both supported work modes:
feature (including the existing absent-field default) and validation-only.
Validation-only cannot use feature Return/corrective Freeze, but its supported
Record-failure, Resume, ResolveBlocker and retirement history still rechecks
artifacts and therefore needs the same custody. Copying an opaque input does
not authorize changes to a validation-only unit's read-only source.

An admitted source-locked unit without a Freeze remains refused by the existing
producer bootstrap boundary. The separate initial source-lock bootstrap has no
admitted Freeze/retirement route; this change preserves its producer behavior
and does not claim immutable NONPASS custody or a new continuation for it.
Snapshot output must be a direct receipt child, with its evidence namespace
already ignored and untracked by the Git repository containing the workspace.
Those prerequisites are checked before publication; an ineligible location
does not silently fall back to mutable evidence.

The writer preflights existing namespace conflicts before publishing new bytes.
If a later I/O or publication error occurs, it preserves unpublished custody
files and reports them explicitly. It does not delete paths after releasing
their handles, because a different actor could have replaced those paths.
Exact existing bytes may be reused; conflicting residual bytes require a new
receipt identity. This retention policy does not claim that a failed publication
left the filesystem unchanged.

The writer does not discover paths recursively inside arbitrary JSON. A typed
`source-delivery-landing` has nested custody requirements and is refused before
writes by this bounded NONPASS snapshot route. PASS receipts and prior receipt
schemas keep their existing semantics. Exact external-evidence selectors may
match a NONPASS snapshot to its authenticated origin only through the closed
manifest and actual retained bytes; passing selector equality stays strict.

## Defective historical source and index references

An old NONPASS receipt may already reference a mutable declared source file or
the repository's actual Git index. If those bytes have changed or disappeared,
ordinary `candidate_freeze.v3` remains strict. Do not rewrite that receipt,
its failed Return transaction, or the event prefix, reconstruct an unavailable
old index, or replace the failure with equivalent new evidence.

The existing `FreezeCandidate` action can instead consume the closed
`candidate_freeze.v4` request. Its exact custody-defect record binds the old
Freeze, Begin and Return transactions, original and retained raw receipt,
artifact ID, literal path, claimed hash, independently derived source/index
class, observed mismatch or absence, and current candidate and control
preimages. The disposition is audit-inert and unavailable. It never asserts
that the missing bytes were preserved or valid and grants no validation,
acceptance, source-scope or proof-reuse credit. Every unaffected artifact and
accepted checkpoint remains subject to its ordinary checks.

The current correction route supports units without a sealed tooling-context
pointer. A different sealed executor context is unsupported by this bounded
repair. The action does not change a context pointer or authorize an upgrade.

## Independent authorization and subsequent actions

This repair requires the independently adopted policy described in
[Native NONPASS Recovery Authority](NATIVE_NONPASS_RECOVERY_AUTHORITY.md).
The executor's committed authority binding pins the actual independent policy
source and complete physical Git closure. An empty binding refuses execution;
a caller-supplied authority directory is only a locator.

Independently qualified repair source and a separate signed, finite owner
decision must match the exact request and freshly observed owner state before
any artifact staging or intent write. Existing static-assessment signatures
retain their own purpose and do not authorize this native effect. Interrupted
transactions remain bound to their original intent, signature and exact
preimage/target states. Completed history authenticates the original issuance
and execution chronology; it does not expire merely because time has passed.

After a committed correction, use the ordinary next action and fresh validation
for the actual changed candidate. Repeated corrections and retirement retain
the original failed evidence and exact typed disposition. A new result earns
credit only through its own normal validation and acceptance route.
