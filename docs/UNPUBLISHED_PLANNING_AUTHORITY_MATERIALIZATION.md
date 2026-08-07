# Unpublished Planning Authority Materialization

`MaterializeUnpublishedPlanningAuthority` is an additive, unreleased one-time
contract for the narrow case where exact project `morphospace/` bytes exist
only in an intentionally dirty source checkout. It is not part of the published
0.6.0 release and does not reinterpret accepted history.

## Decision

Copy exactly the repository-root `morphospace/` workspace below one Git-backed
source repository into a previously absent path below a distinct, clean,
attached Git-backed planning repository. The installed receipt designates the
destination as the sole workspace authority and preserves the source copy as
historical and non-authoritative. The source is neither changed nor deleted.

Eligibility is derived rather than claimed. The source path must be exactly
`morphospace`, its anchor must be exactly `workspace.state.json`, that state
must bind the input project, Git must report dirt in that path, and the complete
live path set plus aggregate tracked diff must differ from the pinned source
`HEAD:morphospace` tree. Equality, including a clean/tracked workspace, is
projection-eligible and rejects. Because v1-v3 project exact published-tree
bytes, this live-versus-pinned-tree divergence is also the deterministic proof
that those routes are inapplicable; caller prose is not accepted as evidence.
`planning_workspace_projection.v1` through `.v3` remain the only published-tree
routes described in
[External Planning Projection And Historical Reconstruction](EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md).

## Portable Input And Receipt

The caller signs off a document conforming to
`unpublished-workspace-materialization-v1.schema.json`. It binds source and
planning repository IDs; each attached branch and full commit/tree identity;
the fixed source workspace and state-anchor paths; a complete ordinal file
path/type/size/SHA-256 inventory; the state SHA-256 anchor; and destination and
receipt paths. The input has no free-form claims surface.

The installed canonical receipt conforms to
`unpublished-planning-authority-receipt-v1.schema.json`. It binds the exact
input SHA-256, both repository identities, source inventory/state anchor,
destination inventory, generated eligibility facts, timestamp, and fixed
authority/nonclaim statements. Portable
documents contain no checkout locations.

This is a planning-control-byte route, not a generic source/runtime payload
copy. Limits are deterministic: input JSON at most 1 MiB and depth 32; 1–512
regular single-link files; 4 MiB per file and 32 MiB aggregate; portable paths
at most 512 characters; JSON depth 32; and JSONL at most 4,096 records with
each line at most 256 KiB. Input and receipt schemas carry the corresponding
inventory, ordinal, and file-size bounds. Hashing is streamed after size checks.

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

Failure removes only the owned stage, the newly installed destination if final
readback itself fails, and empty destination-parent directories created by that
attempt. Pre-existing parents are never removed. A second execution rejects.
On Windows, lexical containment is augmented with stable physical directory
identity obtained from handles opened by `CreateFileW` with
`FILE_FLAG_BACKUP_SEMANTICS` and queried using
`GetFileInformationByHandleEx(FileIdInfo)`. The identity is the filesystem
volume serial number plus 128-bit file/directory ID. Source and planning roots
and Git common directories must be physically distinct. Existing destination
ancestors, the staging parent, stage, and installed destination are bound and
replayed before staging, at the commit point, and through final readback; the
atomic move must preserve the stage directory ID. A `subst` or other namespace
alias therefore cannot create a second authority identity. Execution fails
closed with a bounded error when Windows FileIdInfo is unavailable; portable
inspection and static validation remain possible on other platforms.

Every existing component from each declared repository root through source,
destination parent, stage, and installed destination is checked. Reparse
points, ancestor junctions, multi-link files,
symlinks, non-regular files, invalid JSON/schema IDs, traversal, case ambiguity,
reserved/trailing-dot/trailing-space equivalents, inventory drift, wrong roots
or resolved filesystem/Git identities, shared Git authority,
dirty/detached planning state, overlap, and receipt collisions fail closed.
Unrelated source dirtiness is allowed because selection is limited to the
complete workspace inventory.

This is repeated identity observation, not a handle-relative filesystem
transaction. It trusts the Windows kernel/file-system FileIdInfo result and
assumes the executing principal and kernel are not malicious. A privileged
host actor can still race namespace operations between bounded observations;
the repeated commit-point/readback checks reduce but do not eliminate that
host-level race.

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
