# External Validation Authority

Use this boundary when a pull request changes the policy, workflow, schemas, or
runner that would otherwise validate that same pull request. Ordinary
application changes should keep their normal risk-proportional single-PR
workflow.

The v1 verifier performs static admission only. It reads an active policy from
the exact trusted base tree, inspects fetched candidate Git objects, and either
confirms that no protected path changed or matches the complete candidate diff
to one exact base-approved change set.

It does not check candidate files out, execute candidate code, run tests,
validate an owner effect, accept a work unit, change repository settings, or
authorize publication.

Candidate-side focused and aggregate tests are useful dynamic evidence, but a
validator candidate cannot admit its own protected-path change. Keep that
evidence explicitly non-authoritative until an exact implementation commit and
complete path/blob set pass the trusted-base static admission route below;
dynamic success neither replaces that admission nor grants acceptance or
publication authority.

This boundary also applies when extending a trusted historical validator to
recognize a later owner-ledger schema. Tests must use the existing owner writer
to create positive transactions; hand-authored events or receipts are only
damage fixtures. Preserve prior schemas exactly and admit the new schema only
through complete intent, ledger-predecessor, projection, artifact, completion,
and final-live derivation. Candidate-side success remains dynamic evidence,
not static admission of the protected validator change.

## Two-PR Trust Change

For a validation-authority change:

1. Independently review the proposed implementation commit.
2. Add one exact approval to the base policy in a separate bootstrap or policy
   PR. Bind the reviewed ancestor, the complete changed-path set, and every
   resulting file's exact final Git mode, byte length, and SHA-256.
3. Merge that policy PR through the existing trusted path.
4. Merge the new base into the implementation branch without rewriting the
   reviewed ancestor.
5. Run the base-owned admission workflow. It must read the policy from the
   event's exact base commit and inspect the candidate only through Git
   diff/tree/blob plumbing.
6. Run dynamic validation separately on a credential-free runner. Static
   admission does not attest that a candidate-issued receipt or command ran.
7. Publish only after the repository's required checks and review policy are
   satisfied.
8. Retire consumed approvals from the policy as routine trust-root hygiene.
   An approval can match only while its reviewed `required_ancestor` is in the
   candidate and not yet in the trusted base, so landing the implementation
   makes that approval inert even before cleanup.

The extra PR is intentional at the trust-root boundary. Do not require it for
ordinary source or documentation changes.

## Permanent Policy-Evolution Route

Do not wait until every exact approval is consumed. Before that point,
configure a separate owner-controlled policy-evolution gate whose trust root is
outside the policy being changed. The gate must:

- execute only base-owned code;
- display and bind the exact base/head commits and trees plus the complete
  candidate path, Git mode, size, and SHA-256 set;
- require an explicit repository-owner decision after that evidence exists;
- issue a typed authorization with a unique audit identity that is idempotent
  only for the exact repository, pull request, base, head, tree, artifacts, and
  assessment while it remains fresh;
- retain `candidate_code_executed: false`, `execution_attested: false`, and
  `publication_authority: false` for the static assessment.

This is disclosed external owner authorization, not self-validation. A
standing bypass actor, wildcard hash, candidate workflow, temporary ruleset
removal, or authorization inferred from prior approvals is forbidden. Dynamic
checks, review, acceptance, and publication remain separate. The portable
contract and rationale are summarized in
[Workflow Stability And Feature Throughput](WORKFLOW_STABILITY.md).

### Durable external owner gate

The durable v1 route runs ordinary base-policy admission first. Only the exact
`Protected changes do not match an exact base-approved change set.` outcome may
continue; every other outcome fails. The adapter fetches public PR issue
comments anonymously across bounded pages, with a shared timeout plus
policy-controlled response-byte, comment-count, and comment-size bounds. It
sends no token and performs no write. Exactly one fresh pinned-owner comment
must contain a valid `rusty-morphospace-external-owner-authorization:v1` for the
current evidence. Historical comments for older evidence remain inert audit
history and do not have to be edited or deleted.

The RSA-PSS-SHA256 signed canonical payload binds the issuer and unique audit ID,
repository and PR, exact base/head commits and trees, complete sorted artifact
path/state/mode/size/SHA-256 set, exact assessment SHA-256, issuance, expiry,
decision, and limitations. The public SPKI is pinned in
`config/external-owner-authorization.json`; authorization is limited to 24
hours with at most five minutes of future skew. It permits only the base
verifier to issue that static assessment and explicitly grants no execution,
acceptance, merge, or publication authority.
Required-check reruns are idempotent: the same valid comment may authorize the
same exact evidence again within freshness. It is unusable for any changed
repository, pull request, base, head, tree, artifact, or assessment. Once its
candidate head is an ancestor of the trusted base, it is consumed and inert.
No mutable replay database or exported signing key is introduced.
When no current exact-evidence authorization is valid, the failed static job
emits a fresh canonical typed request containing the complete evidence and
assessment hash. The local helper signs that request-derived payload; it does
not reconstruct evidence supplied by the owner. The successful assessment is
the same assessment whose hash was signed; the authorization ID remains in the
signed authorization document as audit identity rather than rewriting those
assessment bytes.

The safe local helper prints comment text but never publishes it:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\New-ExternalOwnerAuthorizationComment.ps1 `
  -RequestPath <authorization-request.json> `
  -AuthorizationId <unique-audit-id> `
  -IssuedAt <utc-issued-at> -ExpiresAt <utc-expires-at> `
  -CertificateThumbprint <external-current-user-my-thumbprint>
```

Use `-PrivateKeyPemPath <external-private-key.pem>` instead when appropriate.
Exactly one external signing source is required. Private keys and production
certificate thumbprints never belong in portable configuration; tests create
ephemeral RSA keys in process memory.

## Portable Command

Fetch the candidate commit into a clean base checkout without checking it out,
then run:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExternalValidationAuthority.ps1 `
  -RepositoryRoot <trusted-base-checkout> `
  -PolicyPath config/external-validation-authority.json `
  -Repository <owner>/<repository> `
  -BaseCommit <exact-base-commit> `
  -CandidateCommit <exact-candidate-commit> `
  -Json
```

The trusted checkout must be clean and attached to the exact base commit. The
candidate commit must exist in the same object database and contain that base
as an ancestor. Paths are derived with `git diff --name-status -z
--no-renames`; rename sides therefore remain separate deleted and added paths.

The policy and assessment schemas are:

- `schemas/external-validation-authority-policy-v1.schema.json`
- `schemas/external-validation-authority-assessment-v1.schema.json`

The assessment always records:

- exact base and candidate commit/tree identities;
- exact changed and protected path sets;
- the base policy SHA-256 and matched approval, if any;
- `candidate_code_executed: false`;
- `execution_attested: false`;
- `publication_authority: false`.

## Base-Owned GitHub Workflow

The repository-owned `.github/workflows/static-admission.yml` workflow runs on
every pull request targeting `main`. It is deliberately actionless, so there is
no third-party action ref or candidate action to execute. Its first base-owned
PowerShell step creates a new repository under the runner temporary directory,
fetches public `main` without credentials, disables hooks and LFS smudging, and
checks out only the event's exact base commit. Its second step invokes
`scripts/Invoke-ExternalValidationAuthorityForGitHub.ps1` from that trusted
checkout.

The adapter:

- declares only `contents: read`;
- uses no actions or checkout token; any future action must be pinned by full
  commit and keep credentials disabled;
- checks out only `pull_request.base.sha`;
- validates the numeric PR number and full event base/head SHAs;
- fetches the PR head and merge objects into private refs without checkout;
- verifies the event head and binds the fetched merge ref to exact `base, head`
  parents;
- requires the merge tree to equal the exact head tree;
- pins the work-environment verifier commit, tree, entrypoint, and SHA-256;
- invokes only the base-owned adapter and pinned verifier;
- never imports, executes, restores, builds, or extracts candidate content;
- uses no secrets, environments, OIDC, candidate artifacts, caches,
  submodules, LFS, comments, releases, or write permissions.

The base adapter may issue a repository-specific typed assessment that adds
workflow run identity. It must not relabel a static assessment or a
candidate-issued receipt as independent execution evidence.

The workflow's `Static admission` job is static policy evidence only. Keep the
ordinary `pull_request` jobs `quick-linux`, `quick-windows`, and
`standard-windows` separate because those jobs intentionally execute candidate
content. Required-check policy must require both the static job and those
dynamic jobs; neither substitutes for the other. The ruleset must also enable
strict required-status-check handling so a pull request branch is up to date
with `main` before merge. A previously successful head-bound check is not valid
after the base advances. The static workflow includes the `edited` event so a
base-branch retarget receives a new exact-base assessment.

## One-Time Bootstrap

The first merge that installs the adapter cannot be remotely admitted by an
adapter that is not yet present on `main`. Treat that merge as a disclosed
bootstrap exception, not as self-validation. Its pull request record must bind
the exact base commit, candidate commit and tree, complete path set, and each
resulting path's Git mode, size, and SHA-256. It also requires independent
review plus the existing Linux Quick, Windows Quick, and Windows Standard
checks.

The bootstrap may install exact base-policy approvals for separately reviewed
canaries. It must not claim that remote static admission validated its own
workflow, policy, adapter, or tests. After the bootstrap lands, prove the live
boundary with an exact approved protected canary, protected path/byte
substitutions that reject, and an ordinary unprotected change. Only then make
the live static job and dynamic jobs required by the repository ruleset.

## Policy Rules

- Keep exact and directory-prefix protection rules bounded and base-owned.
- List the policy, base adapter, base workflow, and repository-specific
  authority schema paths in `mandatory_protected_paths`. The verifier always
  requires the policy to protect its own path.
- Sort rule IDs, approval IDs, changed paths, and artifact paths ordinally.
- The approval artifact paths must equal its complete changed-path set.
- `present` artifacts bind exact Git mode, size, and SHA-256. `absent`
  artifacts bind an exact deletion.
- Candidate regular-file blobs are limited to 16 MiB each and 64 MiB of
  unique content hashed per invocation. Every Git process has a bounded
  timeout.
- Symlinks, gitlinks, trees, duplicate paths, traversal, backslashes, colons,
  control characters, non-UTF-8 paths, duplicate JSON properties, more than
  512 paths, more than 1 MiB of diff output, oversized blobs, dirty bases,
  stale heads, and non-ancestor candidates reject.
- Replacement refs, shallow repositories, object alternates, and legacy
  grafts reject. Git inspection disables replacement-object interpretation,
  optional locks, filesystem monitors, and external diff execution. The
  base-owned adapter must still start from a newly initialized checkout and
  avoid repository-local hooks, aliases, or other unreviewed configuration.
- Ambient Git repository, worktree, index, namespace, object-store,
  pathspec, shallow-file, and injected-config environment selectors reject
  and are removed from each child process.
- More than one matching approval rejects as ambiguous.
- An approval whose reviewed ancestor is already present in the trusted base
  is consumed and cannot match again.
- A policy change is itself a protected authority change and follows the same
  two-PR process after bootstrap.

Run the focused regression with:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExternalValidationAuthoritySelfTest.ps1
```

The verifier self-test proves exact admission, unprotected bypass, no-overwrite output,
artifact and Git-mode tamper rejection, policy self-protection,
ambiguous-approval rejection, duplicate-key rejection, path-scope and
path-count bounds, reviewed-ancestor enforcement, base ancestry enforcement,
dirty-base rejection, and replacement-ref/alternate-object rejection without
executing the candidate script. It also proves consumed-approval rejection and
rejects inherited Git repository and object-store selectors.

Run the GitHub adapter regression with:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-ExternalValidationAuthorityGitHubAdapterSelfTest.ps1
```

That fixture publishes synthetic PR head and merge refs to a local bare remote.
It proves the positive unprotected path while a candidate marker script remains
absent, then rejects stale or retargeted base, stale head/merge identities,
one-parent, reversed-parent, and exact-parent/wrong-tree merge objects,
malformed event identities, and a substituted verifier pin.
