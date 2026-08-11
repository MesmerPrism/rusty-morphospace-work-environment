# Generic Blocker Resolution

`ResolveBlocker` removes one exact blocker from the current active unit after
validating a `blocker_resolution_receipt.v1`. The contract is product-neutral:
product-specific evidence may reference owner schemas, but those schemas do not
become work-environment authority.

`repository_heads` and `repository_sources` must each exactly cover the
authoritative repository-map entries for the action. Omissions, extras,
duplicates, and unrelated-only sets reject. Each repository source entry binds
one or more current regular files whose bytes justify resolving a blocker in a
dirty worktree.

Source paths use normalized forward slashes and are relative to their mapped
repository. Absolute, drive-qualified, UNC, empty, dot, dot-dot,
trailing-separator, escaping, case-insensitive duplicate, symlink, and reparse
ancestor/target paths reject. Every declared branch, live `HEAD`, and source
file hash is validated initially and revalidated immediately before the
transition-ledger call, so an intervening source edit cannot be consumed. An
attached checkout records its exact branch name. An intentionally detached
materialization records `branch` as the empty string, which must match
`git branch --show-current`; this is exact detached-state evidence, not a
branch-check bypass.

The receipt binds the exact blocker ID, condition, and `resume_when`, a passing
result, hash-bound evidence, current repository heads, dirty source bytes, and
the complete set of other blocker IDs that must be preserved. Unknown fields
reject.

Execution uses the transition ledger. State, unit, and event-tail compare-and-
swap checks run under the workspace mutex before any projection, event, receipt
artifact, or completion write. The action leaves the pending push bundle,
validation checkpoint, acceptance state, current unit, unit bytes, and every
declared preserved blocker unchanged. It appends the existing generic
`state-transition` event, removes only the named blocker, updates
`last_event_id`, and installs the exact input receipt as a transaction-owned
artifact. A consumed receipt or blocker cannot be consumed again.
Consumption identity is stable across paths: retained resolution receipts and
event references are scanned, and the same canonical receipt hash or the same
`receipt_id` + `unit_id` + `blocker_id` tuple rejects even if the caller changes
input/output paths or a later projection reintroduces the blocker. The bounded
scan covers direct JSON files under `receipts/` plus the exact receipt paths
named by blocker-resolution events. Nested product evidence is not interpreted
as a workflow resolution receipt.
Every historical blocker-resolution event must retain one readable,
schema-valid receipt whose project/unit identity matches the event and whose
file hash matches the immutable transaction intent's owned-artifact binding.
The matching committed transition completion must retain the exact
transaction/event/final state-and-unit identities and the recomputed intent
file SHA-256 before any intent-owned artifact hash is trusted.
Missing, malformed, schema-invalid, or hash/identity-inconsistent historical
evidence fails closed until repaired.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action ResolveBlocker `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map> `
  -BlockerResolutionReceipt <project-root>\morphospace\local\<resolution>.json `
  -OutPath <project-root>\morphospace\receipts\<resolution>.json `
  -Execute
```
