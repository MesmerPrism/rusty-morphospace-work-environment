# External Validation Approval Proposals

Use the approval-proposal tool to remove manual path ordering, checkout-byte
hashing, and copy errors from a protected-change review. The tool produces
review input only. It does not approve a change, alter policy, execute
candidate code, attest validation, merge a pull request, or authorize a
release or publication.

## Command

Start from a clean, complete checkout attached to the exact trusted base. The
candidate commit must already exist in the same Git object database, but the
tool does not check it out:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tools\New-ExternalValidationApprovalProposal.ps1 `
  -RepositoryRoot <trusted-base-checkout> `
  -Repository <owner>/<repository> `
  -ApprovalId <lowercase-review-id> `
  -BaseCommit <exact-base-commit> `
  -CandidateCommit <exact-candidate-commit> `
  -OutPath <new-path-outside-the-checkout>
```

The default `required_ancestor` is the exact candidate. This is the narrowest
safe proposal: a later composed candidate may consume it only when the
proposed candidate remains an ancestor. Use `-RequiredAncestor` only when a
different exact, unconsumed commit already ancestors the candidate and the
review intentionally wants that binding.

Omit `-OutPath` to return JSON on standard output. An output path must be
outside the trusted checkout, its parent must already exist, and it must not
already name a file. Output creation uses no-overwrite create semantics and a
durable flush, and rejects a reparse-point output or parent.

## Evidence and bounds

The tool derives the base and candidate commit/tree identities, sorted changed
paths, deletions, regular-file modes, sizes, and SHA-256 values from canonical
Git objects. It does not read candidate working-tree file content. One
aggregate tree read and one batched blob read avoid a Git subprocess per path.

It rejects:

- a dirty or wrong-HEAD trusted base;
- shallow clones, replacement refs, grafts, alternates, or ambient Git object
  overrides;
- a candidate outside the base ancestry;
- an already-consumed or non-candidate required ancestor;
- empty, duplicate, nonportable, or more than 512 changed paths;
- symlinks, submodules, or file modes outside `100644` and `100755`;
- any artifact above 16 MiB, more than 64 MiB of distinct candidate blobs, or
  an aggregate tree listing above 16 MiB.

Git commands are read-only, disable optional locks and external diffs, and use
a 30-second bound. The result records all execution and authority claims as
false.

## Review and installation

The top-level
`rusty.morphospace.workflow.external_validation_approval_proposal.v1` result
has `proposal_status: review-required`. Its `approval_candidate` deliberately
lacks the policy-required `status: approved`, so it cannot be copied into an
active policy as-is.

After reviewing intent, paths, and exact artifact evidence:

1. copy `approval_candidate` into a separate trusted-base policy change;
2. add `status: approved` only in that reviewed change and keep the policy's
   approval IDs sorted;
3. land the policy change through the repository's audited trust-root or
   external-owner procedure;
4. rerun base-owned static admission against the resulting exact base and
   candidate; and
5. collect independent dynamic validation before merge.

The proposal never replaces those decisions or evidence stages.

Run the portable fixture with:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tools\Test-ExternalValidationApprovalProposal.ps1 -SelfTest
```

The fixture covers canonical Git bytes despite a poisoned candidate checkout,
duplicate blobs, executable mode, deletion, deterministic ordering, exact-base
and required-ancestor rejection, deletion-only candidates, unsupported file
modes, output boundaries,
and unchanged refs, worktree registrations, and source status.
