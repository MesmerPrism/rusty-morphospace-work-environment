# Unpublished Planning Authority Materialization

`MaterializeUnpublishedPlanningAuthority` is an additive, unreleased one-time
contract for the narrow case where exact project `morphospace/` bytes exist
only in an intentionally dirty source checkout. It is not part of the published
0.6.0 release and does not reinterpret accepted history.

## Decision

Copy exactly one caller-selected workspace directory below one Git-backed
source repository into a previously absent path below a distinct, clean,
attached Git-backed planning repository. The installed receipt designates the
destination as the sole workspace authority and preserves the source copy as
historical and non-authoritative. The source is neither changed nor deleted.

This route is unavailable when a published Git-tree projection applies.
`planning_workspace_projection.v1` through `.v3` remain the only published-tree
routes described in
[External Planning Projection And Historical Reconstruction](EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md).

## Portable Input And Receipt

The caller signs off a document conforming to
`unpublished-workspace-materialization-v1.schema.json`. It binds source and
planning repository IDs; each attached branch and full commit/tree identity;
source and destination workspace-relative paths; a complete ordinal file
path/type/size/SHA-256 inventory; the caller-declared workspace-state file and
SHA-256 anchor; the destination receipt path; and explicit claims.

The installed canonical receipt conforms to
`unpublished-planning-authority-receipt-v1.schema.json`. It binds the exact
input SHA-256, both repository identities, source inventory/state anchor,
destination inventory, timestamp, and authority/nonclaim statements. Portable
documents contain no checkout locations.

## Execution

Inspect by default:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\MaterializeUnpublishedPlanningAuthority.ps1 `
  -InputPath <materialization-input> `
  -SourceRepository <source-repo> `
  -PlanningRepository <planning-repo>
```

After reviewing the deterministic plan, add `-Execute`. Filesystem repository
locations are local adapter inputs only. Execution validates exact attached
Git identities, requires clean planning and an absent destination, observes
the selected source workspace twice, copies only inventoried files into an
owned same-volume sibling stage, verifies the stage, writes and validates the
canonical receipt, re-observes source bytes and Git identities immediately
before the commit point, atomically installs, and performs final readback.

Failure removes only the owned stage, or the newly installed destination if
final readback itself fails. A second execution rejects. Reparse points,
symlinks, non-regular files, invalid JSON/schema IDs, traversal, case ambiguity,
inventory drift, wrong roots or identities, shared Git authority,
dirty/detached planning state, overlap, and receipt collisions fail closed.
Unrelated source dirtiness is allowed because selection is limited to the
complete workspace inventory.

## Authority And Non-Scope

Materialization is not workflow admission. Later work uses ordinary external-
workspace lifecycle transitions. The contract performs no Git mutation,
worktree/branch creation, state transition, validation, acceptance, source
publication, remote action, force action, build, or device work.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-UnpublishedPlanningAuthorityMaterialization.ps1 `
  -SelfTest
```
