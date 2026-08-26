# Affected Validation

Affected validation selects the smallest dependency closure that could have
changed while preserving a fail-closed route to the existing full gates. It is
not a changed-file allowlist and it is not validation authority.

The v1 registry maps tracked path sets to owner checks, check prerequisites,
contract providers and consumers, platform support, budgets, and cache policy.
The resolver binds an exact clean head checkout, explicit base and head commits
and trees, and the head-tracked canonical registry. It reads their Git object
diff, expands prerequisites and reverse consumers, and emits a canonical
`rusty.morphospace.workflow.affected_validation_plan.v1` shadow plan.

V1 never executes a check, skips a required check, reuses a proof, records
validation, accepts a unit, or authorizes publication. Unknown, ambiguous,
case-colliding, or trust-root changes select the full Deep plan; non-ancestral
or clean-head-drifted inputs are rejected before a plan is emitted.
Changes to the selector, its registry, CI/aggregate routing, shared canonical
JSON/byte logic, or external validation authority always select Deep.

Run the shadow resolver with exact immutable Git identities:

```powershell
pwsh -NoProfile -File ./scripts/Resolve-AffectedValidation.ps1 `
  -RepositoryRoot <repo-root> `
  -BaseCommit <full-base-sha> `
  -HeadCommit <full-head-sha> `
  -Tier Quick `
  -OutPath <out-dir>/affected-validation-plan.json
```

Promotion to affected-only execution requires a separately reviewed package,
representative shadow parity with the full suite, a rollback decision, and
periodic full Deep sampling. Any missed failure invalidates the registry
revision. Device, attended, remote-state, nonce-bound, and expiring authority
evidence is never reusable.

The inert `validation_check_proof.v1` schema records the eventual proof-key
boundary: exact check entry, command and transitive input closure, platform,
toolchain, environment, and runner identities. A cache is untrusted transport;
only an exact passing typed proof may later become reusable.
