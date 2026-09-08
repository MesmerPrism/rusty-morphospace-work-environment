# Validation-Only Write-Scope Narrowing

`NarrowValidationOnlyWriteScope` removes declared paths from the exact current
`validation-only` unit without changing source bytes or repository identities.
It is available only while that unit is `active` or `validating`, before any
same-unit validation checkpoint or normal-validation selector exists. Empty
`allowed_paths` arrays describe a read-only snapshot observation. New
validation-only proposals should use empty arrays from the start for unchanged
observed source rows; they do not need this corrective action. A nonempty
validation-only path remains limited by the existing `morphospace` scope rule,
while feature units and units with omitted `work_mode` still require a
nonempty path list.

The `validation_only_write_scope_narrowing.v1` request binds the raw and
canonical project, state, and unit preimages; the ledger prefix; repository-map
and exact source-lock bytes; and complete before/after repository rows. The
after rows must retain their order and identities, be exact subsets of the
before rows, remain inside project authority, and remove at least one path.
Every mapped source repository must still be the exact clean locked commit and
tree.

Review the default dry run, then replay its request hash for execution:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action NarrowValidationOnlyWriteScope `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <repository-map.json> `
  -ValidationOnlyWriteScopeNarrowing <request.json> `
  -OutPath <project-root>\morphospace\receipts\<narrowing-id>.json

pwsh -NoProfile -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action NarrowValidationOnlyWriteScope `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -RepoMapPath <repository-map.json> `
  -ValidationOnlyWriteScopeNarrowing <request.json> `
  -ExpectedValidationOnlyWriteScopeNarrowingSha256 <dry-run-sha256> `
  -OutPath <project-root>\morphospace\receipts\<narrowing-id>.json `
  -Execute
```

Execution copies the reviewed request byte-for-byte to the receipt path and
uses one v6 transition-ledger transaction. The unit changes only in
`allowed_repositories`; workspace state changes only in `last_event_id`; the
project projection is required to be canonical and remains byte-identical.
An interrupted execution can be replayed only from its exact authenticated
intent with `-Execute`.

The receipt proves only this declaration change and preservation of observed
source bytes. It does not prove validation, acceptance, publication, Git,
build, device, or remote work.
