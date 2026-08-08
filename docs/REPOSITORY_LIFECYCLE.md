# Repository Lifecycle Advisory

Use the repository lifecycle advisory to classify remote branch refs and their
local worktree consumers before an owner considers retirement. It is a
read-only evidence boundary, not a deletion tool, cleanup transaction, merge
decision, or GitHub policy authority.

The contract is intentionally split:

1. a local registry records the exact remote tip expected for each ref and the
   evidence status for every possible operational consumer;
2. `scripts/Inspect-RepositoryLifecycle.ps1` re-reads the live remote heads,
   current default-branch tree, local worktree registrations, dirty-worktree
   count, and commit ancestry without fetching or changing Git state;
3. the result classifies each ref as `candidate-retire`, `hold`, or
   `incomplete` and always records `execution: not-performed`;
4. any later retirement remains a separate repository-owner transaction with
   an unchanged-tip lease, recovery manifest, ref-absence readback, and proof
   that owner main did not change.

The shared schema is
`schemas/repository-lifecycle-advisory-v1.schema.json`. It validates both the
input registry and output advisory result.

## Strict consumer registry

Every ref must carry all ten checks, even when the answer is `no`:

- open pull-request use;
- protected-ref status;
- Pages use;
- workflow use;
- release use;
- deployment use;
- active task or writer use;
- registered worktree use;
- dirty or unique local-work consumer;
- evidence or named-hold consumer.

Each check records `yes`, `no`, or `unknown`, one or more evidence references,
consumer identities when the answer is `yes`, and an exact reevaluation gate.
`yes` without a consumer identity rejects. `no` with a consumer identity also
rejects. `unknown` is never treated as absence.

Evidence references may point to private ignored records. Do not publish local
paths, task identities, dirty fingerprints, private PR data, or unsanitized
hold reasons merely because the portable schema can represent them.

## Dispositions

`candidate-retire` means only that all required consumer checks are complete,
the exact live tip still matches the registry, the tip is reachable from the
current default branch, and no consumer was found. It still requires explicit
repository-owner release and a separate recovery transaction.

`hold` means the evidence is complete and at least one real consumer or
structural reason remains. Default, protected, open-PR, Pages, workflow,
release, deployment, active-writer, registered-worktree, dirty-unique,
evidence-held, and divergent refs are holds.

`incomplete` means evidence is unknown, a live tip changed or disappeared, the
main ancestry object is unavailable, or live registered-worktree state
contradicts the registry. Refresh the named evidence; never convert incomplete
to a retirement candidate by assumption.

A stale or unreadable registered worktree is counted separately from known
dirty worktrees. If it names an inspected branch, that ref is `incomplete`
until the registration is repaired or released; a failed status read is never
treated as a clean worktree.

Confidence describes evidence completeness, not deletion safety. Even a
high-confidence retirement candidate has no execution authority.

## Worktree and source-policy ordering

Release worktree consumers owner by owner. Preserve dirty or unique work and
obtain an exact owner handoff before retiring a remote branch name. Remote ref
retirement and local worktree/branch removal are separate transactions; do not
combine them for convenience.

Before a repository adopts a new line-ending or other byte-level source
policy, resolve that repository's divergent, dirty, or local/remote-tip-
mismatched legacy refs. Preserve exact commits and re-admit still-wanted slices
from current main. Do not wholesale-merge a stale branch and do not let a new
text policy retroactively decide the branch's fate. An unresolved ref in one
repository does not block a disjoint owner's adoption.

Branch-name evidence consumers should eventually move to content-addressed
commit, tree, and receipt identities or to an explicit operational owner
contract. Historical receipts remain immutable; replace live name dependence
without rewriting prior evidence. Deployment, release, Pages, and legitimate
long-lived development refs remain held until their owners redesign the
operational contract.

## Read-only command

Prepare the registry under an ignored local directory, then run:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Inspect-RepositoryLifecycle.ps1 `
  -RegistryPath <repository-lifecycle-registry.json> `
  -OutPath <repository-lifecycle-advisory.json>
```

The inspector may contact the configured Git remote only through
`git ls-remote --heads`. It does not fetch, checkout, update a ref, delete,
prune, run GC, change a worktree, edit GitHub settings, or emit a deletion
command. It refuses to overwrite an existing report.

Run the focused fixture with:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Test-RepositoryLifecycleInventory.ps1 -SelfTest
```

The fixture covers a reachable consumer-free candidate, default/open-PR/
worktree/divergent holds, unknown evidence, an unreadable worktree registration,
exact-tip drift, deterministic output, no Git mutation, and a damaged strict
registry.

## Steady-state hygiene

Generate a new advisory retirement candidate when a feature branch is merged
or an owner unit is accepted. The candidate is then either released through a
separate exact-tip transaction or retained with a named consumer and
reevaluation gate. Periodic portfolio scans verify those dispositions; they do
not replace the merge-time owner decision.
