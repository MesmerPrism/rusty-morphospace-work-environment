# Inherited-Candidate Evidence And Reference Materialization

## Decision and scope

An inherited candidate may enter a new feature unit only as sealed,
task-local evidence. It is never a live product input, a writable source
overlay, validation evidence, or acceptance authority. This contract is for a
portable archive, raw patch, manifest, and exact file inventory retained from
an earlier task when the original source checkout is deliberately out of scope.

The unit declares only the path and SHA-256 of an
`inherited_candidate_evidence_binding.v1` below
`inherited-candidates/<binding-id>/`. The binding and its manifest repeat one
clean historical base/head/tree pair, the exact assets, and the required
nonclaims. Claim verifies every sealed byte and archive entry from a clean
checkout; it does not open another product checkout, apply the patch, or copy
any inherited byte into a declared product repository.

This is additive. Units without `inherited_candidate` preserve the ordinary
Claim and historical-compatibility routes.

## Evidence shape

Use the five strict schemas together:

- `inherited-candidate-evidence-binding-v1.schema.json`
- `inherited-candidate-manifest-v1.schema.json`
- `inherited-candidate-file-inventory-v1.schema.json`
- `inherited-candidate-materialization-marker-v1.schema.json`
- `inherited-candidate-materialization-progress-v1.schema.json`

The binding and manifest name the same `archive`, `patch`, and
`file_inventory` files, each with a portable task-local path, length, and
SHA-256. The inventory is ordinally sorted and carries every archive file's
path, length, SHA-256, and `100644` or `100755` ZIP Unix mode. The archive is
read directly, not extracted through an ambient shell command. Duplicate,
case-equivalent, parent-traversing, reparse-backed, missing, substituted, or
mode-mismatched entries reject.

The historical base/head/tree values establish provenance only. The workflow
does not resolve them through a live repository and they do not make archived
bytes a source-composition dependency.

## Claim and materialization protocol

`Claim` verifies the binding before it changes state. It must record the exact
binding path in its Claim event. A unit with a binding remains source-work
blocked until it has an exact materialization marker.

Immediately after Claim, materialize a review-only task-local reference:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action MaterializeInheritedCandidate `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <local-repository-map.json> `
  -MaterializationRoot <task-local-reference-root> `
  -OutPath <project-root>\morphospace\receipts\<binding-id>-materialized.json `
  -Execute
```

The root must already exist, be outside the workflow workspace and every root
in the supplied repository map, and contain no reparse traversal. The action
extracts only the already verified archive to the binding's fixed leaf,
verifies the complete output inventory again, and installs the marker through
the transition ledger.
It never applies the raw patch; the patch is retained and hash-verified as
historical evidence. The marker records no absolute path, only the fixed leaf,
the Claim event, exact asset hashes, inventory fingerprint, mode verification,
and the three nonclaims.

Before it creates a stage or destination, the action writes a strict task-local
progress record. That record binds the exact Claim, evidence hashes, destination
root fingerprint and leaf, marker bytes, and state/unit/event CAS preimage. It
is not an authority receipt and never describes a product checkout. It solely
allows the identical request to resume an interrupted materialization without
stranding unowned external bytes.

The first execution refuses any existing destination, stage, marker, or ledger
intent that lacks this authenticated progress record. A retry verifies and
resumes exactly one of: a verified stage; a verified destination; an installed
ledger marker; or a committed ledger completion. It rejects mixed stage and
destination states, path/hash/Claim/root/CAS drift, a marker without its ledger
intent, and any substituted or damaged bytes. The transition ledger owns marker
installation and the state/unit/event projections; successful completion clears
the progress record. A crash after ledger completion is likewise recovered by
the exact replay. Once an exact marker exists, an exact re-run verifies the
existing reference and reports `inherited-candidate-already-materialized`
without writing again. A missing, replaced, or damaged destination is not
repaired by rematerializing over it; it fails closed for owner recovery.

## Authority and validation

The materialization marker is a source-work prerequisite only. It does not:

- authorize validation or acceptance;
- add a product input or source-composition dependency;
- authorize Git, remote, device, or external mutation; or
- assert that the historical patch is correct, applied, or accepted.

`FreezeCandidate` and later validation-facing owner steps must require the
marker for units that declare inherited evidence. Validation and acceptance
continue to require their ordinary fresh, exact-scope receipts.

## Verification

Run the focused self-test after changing this contract:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-InheritedCandidateMaterialization.ps1 -SelfTest
```

It covers Claim-bound task-local evidence, source-free archive verification,
base/head/tree manifest agreement, ZIP mode and inventory checks, post-Claim
materialization, marker gating, exact replay, destination damage, raw-patch
substitution rejection, and injected interruptions after staged extraction,
destination installation, marker installation, and ledger commit. Each cut
must resume to one event and a final idempotent replay; conflicting staged and
destination bytes must reject.
