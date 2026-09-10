# Full Authority Mode

Full Authority Mode is an explicit, revocable delegation from a user to the
agent operating one Rusty Morphospace task. It lets that agent continue within
the declared scope, make informed implementation and workflow decisions, and
perform the resulting actions without asking the user to approve each step.
It changes the conversation-level authorization boundary; it does not weaken
repository contracts or turn evidence into authority.

## Activate And Scope

Activate the mode only from a direct user instruction such as:

> Enter Full Authority Mode until I tell you otherwise.

A request to design, document, or explain the mode does not activate it. The
activation applies to the task in which the instruction is given and to the
project or ecosystem scope declared by the user. If the user names no narrower
scope, use the current project's owner-declared participating repositories,
their configured remotes and pull requests, their owned publication targets,
and devices already identified and authorized for that project. A new
repository, remote, publication target, or device requires a user-declared
scope expansion. Changing directories, branches, worktrees, turns, or models
does not revoke or expand the scope.

The mode remains active across turns, compaction, completion of individual work
units, and an application restart that restores the same task history, until
the user explicitly revokes it or supersedes it with narrower instructions.
The task's conversation history is the primary activation record. Preserve the
activation wording, scope, limits, and latest revocation state in a private
continuation or handoff when work moves beyond that history. Never commit a
user's active grant, credentials, machine details, or private task state to
this portable contract. On continuation or handoff, verify the recorded grant
and latest limits against the available task history before relying on the
mode. If that provenance is missing or contradictory, continue independently
authorized work and resolve the delegation before performing actions that
depend on it.

An agent may give a delegated worker the same or a narrower operation only
when the parent supplies the activation provenance and scope. The parent
remains responsible for the result. Another task or agent may not infer Full
Authority Mode from this document, a previous approval, or another task's
activation.
The parent must promptly propagate revocation, narrowing, or pause instructions
to active workers and cancel queued affected work where supported. A worker
must stop further affected dispatches when informed.

## Granted Operation

Within scope, the agent may make the decisions needed to complete the work and
may perform implementation, review, tests, builds, lifecycle actions, cleanup,
archive or deletion, commits, non-force pushes, pull-request and workflow
operations, exact external-owner signing and posting, merge, publication, and
device operations. It may repair recoverable failures and issue a replacement
exact authorization after candidate evidence changes without another user
prompt.

Every action still follows its owning contract. Full Authority Mode does not:

- expand repository, path, privacy, credential, device, or resource scope;
- bypass Agent Board leases, branch protection, platform controls, or a
  higher-priority instruction;
- convert validation evidence into acceptance, merge, publication, or device
  evidence;
- permit a wildcard or candidate-independent authorization;
- excuse missing, stale, failing, ambiguous, or fabricated evidence; or
- grant a capability, credential, legal right, or third-party authority that
  the user and agent do not have.

Use the least costly trustworthy validation and preserve unrelated work. Stop
only the affected action when a required credential or capability is absent,
the requested action is outside the active scope, a public/private boundary
cannot be resolved, resource ownership is unsafe, a higher-priority rule or
platform control denies the action, or the evidence cannot support an informed
decision. Resolve recoverable conditions autonomously and continue independent
in-scope work.

## Exact External-Owner Decisions

For validation trust-root changes, the mode delegates the owner's decision to
the active agent; it does not create standing static admission. The agent must
inspect the fresh request and candidate evidence, sign only the exact
request-derived payload with the approved external signing source, and post
that exact comment. Each signature remains bound to its repository, pull
request, base and head commits and trees, complete artifact set, assessment,
freshness window, and audit identity. A changed candidate requires fresh
evidence and a new signature. The base-owned verifier and all stated
limitations remain unchanged.

The agent may exercise this external-owner delegation only when the activating
user is the repository owner recognized by the gate, or already holds a
policy-recognized delegation, and the approved signing source and posting
identity are available. Otherwise the mode still authorizes other in-scope
work, but the external-owner comment remains blocked at its existing authority
boundary.

## Revoke Or Limit

The user may say `Exit Full Authority Mode`, `Revoke Full Authority Mode`, or
give an equivalent direct instruction. Revocation takes effect immediately for
actions not already dispatched. A narrower instruction limits the grant. A
pause instruction preserves the grant but blocks new mutating or external
actions until the user explicitly resumes work; read-only status preservation
may continue when safe. Record the latest state in any private handoff so a
resumed agent does not rely on an obsolete grant.

Revocation cannot invalidate an external-owner v1 comment already issued. That
comment remains subject to its exact candidate binding, expiry, and consumption
rules. If immediate invalidation is required, use the external gate's owning
key or policy-evolution procedure.
