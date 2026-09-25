# Accepted validation evidence relocation

Use this narrow owner route when an idle, accepted local-only planning
workspace has a passing v1 validation receipt whose raw, receipt-relative
artifacts were placed outside its ignored `local/` area. It changes evidence
storage without repeating validation or acceptance. The original accepted
receipt, unit, and event-ledger prefix remain byte-exact.

The route accepts only an immediate correction of the current accepted event.
It covers every artifact in receipt order. Rooted artifact paths, partial
maps, different hashes, reparse points, tracked originals or destinations,
nonignored destinations, an active unit, and pending publication reject. The correction
receipt contains only workspace-relative paths and hashes. It contains no raw
log bytes or machine paths.

1. Copy every raw artifact byte-for-byte into one ignored
   `<workspace>/local/<relocation-id>/` directory. Keep each original until
   the correction transaction has completed. Verify that Git ignores the
   copies and does not track them.
2. Create an exact input in ignored local storage:

   ```powershell
   pwsh -NoProfile -File <owner>/scripts/New-AcceptedValidationEvidenceRelocationInput.ps1 `
     -WorkspaceRoot <workspace> -UnitId <accepted-unit> `
     -LocalDirectory local/<relocation-id> -CreatedAt <utc-timestamp> `
     -OutPath <workspace>/local/<relocation-input>.json
   ```

3. Use `Invoke-WorkUnitAutomation.ps1 -Action RelocateAcceptedValidationEvidence`
   with `-AcceptedEvidenceRelocation <input>`,
   `-ExpectedAcceptedEvidenceRelocationSha256 <input-raw-sha256>`, and
   `-OutPath <workspace>/receipts/<relocation-id>.json`. Dry-run first;
   then use `-Execute` with the same bytes. The action appends one
   hash-bound transaction and only changes `workspace.state.json`'s
   `last_event_id`.
4. Verify the committed correction with current-work validation. Remove the
   original raw files from their old receipt paths only after the transaction
   and local-copy hashes pass. Commit the planning control files without the
   raw logs. Run source-only publication readiness and plan generation against
   that clean planning commit.

If execution is interrupted, retain both sets of raw bytes and call the same
action with the same input and `-Execute`. It checks the persisted intent and
repairs only that transaction. Cleanup of the original copies follows a
successful committed proof. While this correction remains in the current
suffix, current-work and source-only consumers fail closed if a local copy is
missing or changed. After a later acceptance seals it into history, ordinary
current-work follows the accepted boundary and does not require the old local
archive. A source-only publication bound to this correction rechecks the
local bytes while the correction remains its prepublication tail; an ordinary
rerun never fabricates accepted evidence.

Source-only publication binds the original acceptance event and receipt and
also binds the relocation as the exact prepublication event tail. Its plan,
preparation, and recording recheck the ignored local bytes. This route does not
publish source, grant device evidence, or license a general path fallback for
other validation receipts.
