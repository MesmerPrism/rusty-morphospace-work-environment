# Retiring active work before changing direction

Use `RetireActive` when an explicitly reviewed change of direction requires a
new objective or development envelope. It closes the current work without
accepting it and returns the project to idle. It preserves the old unit and
its existing evidence byte-for-byte.

`SupersedeActive` remains the direct replacement route within the old unit's
write scope. `AmendActiveWriteScope` remains a bounded correction within the
existing objective, project and agent envelope. Neither action authorizes a
different product architecture or new source authority.

## Review and retire

1. Preserve implementation checkpoints and distinguish them from accepted
   product evidence. Record the reason for retiring the work and a distinct
   intended replacement identity.
2. Observe the complete current source composition and every repository the
   old unit may write. Bind clean commits and trees. Checkpoint owned changes
   and resolve unowned dirt before retirement; the action does not delete,
   merge, discard or transfer source.
3. Prepare the exact owner request against the current project, feature lock,
   compact state, event ledger, repository map and unit. Review the dry run
   and execute only its exact SHA-bound request.
4. Verify the committed owner transaction and retirement receipt. The old
   unit remains immutable evidence. The authenticated current-work view
   classifies it as retired active work, not an accepted prerequisite.

The reviewed input may live in ignored local storage outside the workspace.
Execution preserves its exact bytes at
`receipts/<retirement_id>-request.json`, alongside the distinct retirement
receipt. This avoids requiring a planning request to bind the Git commit that
contains itself. Initially observed source repositories must be clean and
backed by distinct Git repositories. Writable entries must map to their exact
Git roots and retain their locked baseline as an ancestor. A read-only source
dependency may map to an authenticated nested directory, as permitted by the
preparation-owned repository map and source lock; retirement observes the
complete backing Git repository and requires its exact locked commit, tree,
role, and clean worktree. Nested writable or planning entries, duplicate
backing repositories, path traversal, and reparse-backed aliases are rejected.
The lock's `materialization_path` remains the producer's materialization label;
retirement does not reinterpret it as a Git-relative path.

A project-shell read-only planning repository may instead retain the exact
owner-produced lifecycle projection when it strictly contains the active
workspace. The original preparation lock may still be HEAD with unstaged
lifecycle dirt, or a clean current HEAD may be a linear descendant of that
lock whose commits change only authenticated projection paths. This exception
accepts only the final-byte projection of an authenticated
`Prepare`/`Admit`/`Ready`/`Claim` chain, or its exact
`Prepare`/`Admit`/`RetireProposed`/`Admit`/`Ready`/`Claim` replacement form,
followed by zero or more contiguous same-unit `AmendActiveWriteScope` and
`UpgradeToolingContext` transactions. Every continuation is revalidated by its
owning historical semantic verifier. An upgrade also binds the exact
compatibility, publication, protocol, and affected-validation proof files
referenced by its authenticated request and resulting tooling context.
The verifier applies last-writer wins in ledger order and rejects staged
changes, deletes, renames, conflicts, outside-workspace paths, pending
artifacts, incomplete transactions, and target, artifact, intent, or completion
drift. For a committed descendant it also checks every changed path in every
intervening commit and the live bytes against the authenticated projection;
unrelated paths remain forbidden even if a later commit reverts them. This
grants no general planning drift or arbitrary descendant-HEAD allowance.

```powershell
pwsh -NoProfile -File <work-environment>/scripts/Invoke-WorkUnitAutomation.ps1 `
  -Action RetireActive -WorkspaceRoot <workspace> -UnitId <old-unit> `
  -RepoMapPath <repository-map> -ActiveUnitRetirement <reviewed-request.json> `
  -ExpectedActiveUnitRetirementSha256 <request-sha256> `
  -OutPath <workspace>/receipts/<retirement-id>.json -Execute
```

Conflicting queued work, validation selection, publication or incomplete
transactions must be resolved through their owners first. A retirement is not
a way to hide damaged current history or a failed transaction. Exact retries
authenticate the original transaction; they do not append another retirement
or overwrite retained evidence.

An old, never-admitted proposal is excluded only when the ordinary preparation
classifier proves it inert against the authenticated owner control surface.
It remains byte-exact; a queued, admitted, referenced or in-flight proposal
receives no exemption. The named replacement must still be absent.

## Prepare the replacement

Once the project is idle, checkpoint the completed planning retirement so the
next preparation observes a clean current planning source. Then use ordinary
`PrepareDevelopmentEnvelope` to review
the revised repository roots, feature closure, permissions, build and device
ceilings. Bind fresh clean source identities. Then use `AdmitDevelopmentUnit`,
`Ready`, `Inspect` and `Claim` for the named replacement.

The new unit must state which earlier implementation checkpoints it retains
and which outcomes remain unverified. Retirement does not create the new unit,
grant source or device work, validate a candidate, accept either unit or
publish anything. Do not manufacture an accepted or blocked result merely to
reach an idle state. Do not create a placeholder successor to bypass the
supersession scope check.

## Validation

Use the focused retirement and continuation checks. Positive fixtures must be
produced by the actual owner actions. Cover dry-run nonmutation, exact replay,
interruption recovery, source/overlay drift, conflicting current authority,
damaged transaction evidence and preservation of old bytes. Continue through
fresh preparation, admission and ordinary claim; reject attempts to resurrect
the old unit or use it as accepted evidence.

The affected-validation registry partitions the focused retirement owner into
bounded scenario leaves. The core leaf depends on every nested-source,
amendment, recovery and damage leaf before it provides the retirement contract;
one scenario cannot stand in for the complete focused result. Direct manual use
of `Test-ActiveUnitRetirement.ps1 -SelfTest` still runs every scenario.

Historical auditing remains separate. Later continuation must authenticate
retirement after subsequent owner events without retrofitting new instruction
requirements onto the retired unit.

## Read-only planning source and lifecycle projection

Retirement uses the shared [planning lifecycle projection contract](ACTIVE_DEVELOPMENT_ENVELOPE_EXTENSION.md#read-only-planning-source-and-lifecycle-projection). Its existing caller-authenticated admission route and replacement-unit compatibility remain intact; extraction adds no ordinary-only preparation prerequisite to retirement.

The planning source commit/tree stays immutable. Only exact authenticated owner lifecycle projections can explain a nested planning descendant or current own-transition dirt. Declared immutable content, including legitimate additive readonly leaves derived from owner authority, gains no lifecycle-content exception.
