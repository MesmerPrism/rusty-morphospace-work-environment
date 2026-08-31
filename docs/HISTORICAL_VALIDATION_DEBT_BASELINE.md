# Historical Validation-Debt Baseline

Use this narrowly scoped trust-root mechanism only when a complete cold
workflow aggregate identifies pre-existing, immutable historical debt while the
current active or validating feature unit still satisfies its current contract.
It quarantines an exact failure set; it never repairs history or declares the
workspace clean.

## Capture and authorization

`New-HistoricalValidationDebtBaseline.ps1` first runs the complete aggregate in
a fresh child process and emits a canonical, non-empty failure-set request. Its
normal mode is a dry run. `-Execute` can install exactly one immutable request
at `receipts/historical-validation-debt/<baseline-id>/baseline.json`; it does
not authorize that request, mutate source, run a build, execute a device step,
or accept a unit.

The baseline binds the project ID, validator commit/tree and a closed ordered
manifest of aggregate scripts, modules, schemas, templates, lifecycle, and
external-owner policy inputs; it also binds project specification, source lock,
repository map, exact state bytes, event-ledger prefix length/hash/tail,
current active-or-validating-unit identity and raw/canonical bytes, and a
sorted duplicate-free set of structured failure records. Entries
are closed to non-current terminal legacy-unit metadata failures and explicitly
classified legacy workspace-state failures. Current-unit, instruction-surface,
source-scope, validation, acceptance, unknown, tool, and transport failures are
not baselineable.

## Focused observability and evidence reuse

The focused owner self-test is not the production baseline action. It runs the
synthetic workspace/current-history contract in a bounded child with unrelated
owner self-tests disabled, then constructs one exact baseline-evidence file
from that capture. The evidence reuse key binds validator identity,
workspace/event-ledger anchor, source composition, current-unit raw bytes, and
the canonical failure-set digest. Installing that exact evidence into the
synthetic workspace does not rerun the superseded-unit capture and does not
authenticate, authorize, validate, or publish it; the later synthetic
owner-signature path remains mandatory.

Every directly launched phase writes create-new start and terminal receipts
plus raw stdout/stderr files. The terminal binds command bytes and arguments,
elapsed time, exit/timeout state, stream hashes and lengths, bounded diagnostic
streaming, and child-tree cleanup. Typed results distinguish timeout,
fixture-cleanup failure, cache miss, code failure, evidence collision, and
evidence-reuse rejection. A phase collision never overwrites prior bytes.

A history-archive checkpoint is not a reusable historical-debt result. It can
authenticate archived raw-byte integrity and live-tail closure, but it cannot
prove that an aggregate or historical-debt ratchet passed. Ordinary production
capture remains cold and complete; the focused evidence path exists only to
avoid recursively replaying unrelated owner self-tests inside this damage
suite.

An independent owner must separately sign the canonical sibling
`authorization.json` using the pinned external-owner RSA-PSS authority. The
signed payload binds the exact baseline hash, all validator/workspace/source
identities, current-unit identity, failure-set digest/count, workspace-unique
nonreplayable authorization and audit IDs, issuance, expiry, and a decision limited to this
unresolved historical debt. A signature grants no validation, acceptance,
source/workspace mutation, publication, or merge authority. The immutable
content-addressed sibling prevents a different request from being installed
under an existing authorization; repeated read-only verification of the same
unexpired exact bytes is not a state transition.

## Ratchet

Without an installed and valid authorization, aggregate behavior is unchanged:
any failure fails. With one, the aggregate recomputes the whole failure set in a
cold process. The set must equal the authorized sorted set exactly. A new,
removed, duplicate, reordered, relabeled, altered-message/evidence failure,
validator/source/state/ledger-prefix drift, signature issue, or a failure in a
post-baseline/current path is a contradiction and fails normally.

On the only successful path, the result schema reports
`current_validation=passed`, `historical_debt_present=true`, the baseline ID,
and exact debt count/digest with `status=debt-bearing-success`. This is not a
clean-workspace claim. A ratcheted aggregate must save the result at the exact content-addressed
path `receipts/historical-validation-debt/<baseline-id>/results/<current-unit-
raw-sha256>.json`.

When that exact current-unit result exists, any v1 validation receipt for the
unit must carry its `historical_validation_debt` binding to the exact baseline,
authorization, and result. Receipt validation verifies all three hashes,
closed schemas, outcome truthfulness, failure-set equality, and the pinned
authorization signature; acceptance revalidates the receipt in the usual way.

## Boundaries

Do not use a baseline as an ignore list, a generic unit editor, an alternative
to historical adoption/correction, or a way to make a current unit, source
scope, instruction record, validation command, acceptance proof, signature, or
tool crash pass. Do not add project-specific exceptions or private evidence to
this public contract. Re-baselining a changed failure set requires a newly
captured request and fresh independent authorization.

This is validation policy. Candidate dynamic tests are evidence only; protected
changes still use the external Static Admission route in
[External Validation Authority](EXTERNAL_VALIDATION_AUTHORITY.md).

Run the focused observability damage suite before the debt leaf:

```powershell
pwsh -NoProfile -File .\scripts\Test-HistoricalValidationDebtPhaseRunner.ps1 -SelfTest
pwsh -NoProfile -File .\scripts\Test-HistoricalValidationDebtBaseline.ps1 -SelfTest
```
