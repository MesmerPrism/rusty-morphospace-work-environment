# Affected Validation

`validate.yml` resolves a closed, exact-base/current-head plan before running
candidate validation. The registry owns canonical path classes, prerequisite
order, platform applicability, and the exact Git blob identities that evidence
must bind. Unmapped paths, case collisions, selector/workflow changes, and external
authority changes fail closed to Deep; they do not silently widen a Quick run.

Each selected check runs in one bounded child process. Its exit code, timeout,
and stdout/stderr hashes and byte counts are recorded in typed evidence. A
zero-check platform request is invalid. A nonzero exit, timeout, output flood,
or post-kill drain overrun is `code-fail`; `infra-fail` is reserved for a
process-start or host fault. Both write typed evidence before the job fails.

PR runs preserve content-addressed plan and evidence artifacts. A main push
may reuse them only when its ordered merge parents, exact candidate tree,
workflow bytes, ancestor base, PR/run/check identities, artifact bytes, and
freshness all authenticate through `Test-AffectedValidationReuse.ps1`.
Otherwise the main job runs only its current delta. No historical aggregate
receipt is reusable: scheduled/manual Deep checks out full history and runs the
current Deep aggregate. Neither evidence shape is publication or acceptance
authority.

The pre-job infrastructure classifier observes the closed `git`, `pwsh`, and
`rg` set, but requires only `git` and `pwsh` for the registered PR commands.
`rg` is optional at this boundary. A second missing required tool state fails
as `pending-infra`; the workflow records no false success. Hosted zero-job/startup
incidents are observed externally and handed off read-only, because no job can
reliably observe its own absence. See
`scripts/Test-AffectedValidation.ps1` for portable damage fixtures. Selector
trust-root PRs also run the bounded topology and reuse self-tests through the
same affected-validation executor.
