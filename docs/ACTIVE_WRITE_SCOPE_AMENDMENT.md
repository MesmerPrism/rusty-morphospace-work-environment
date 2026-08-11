# Active Write-Scope Amendment

`AmendActiveWriteScope` keeps a bounded feature unit moving when implementation
discovers another writable path or repository that the project already
authorizes. It is an additive unit-scope action, not a project-authority change.

Use it only when all of these remain true:

- the named unit is the exact current `active` feature unit;
- the same captain, objective, authority, publication boundary, and rollback
  envelope still apply;
- every added path is inside the matching repository allow-list in
  `project.spec.json`;
- no existing unit path is removed; and
- the amendment does not turn validation-only work into implementation.

The input satisfies
`schemas/active-write-scope-amendment-v1.schema.json`. It binds the current
project revision and canonical project/state/unit hashes, plus the byte-exact
event-ledger hash, length, and tail. `before_allowed_paths` is the complete
current path set for the repository; it may be empty only when adding a
repository row that is already declared by the project. `after_allowed_paths`
must retain the full before set and add at least one path.

Start from `templates/active-write-scope-amendment.example.json`. Dry-run first:

```powershell
$plan = pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action AmendActiveWriteScope `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -ActiveWriteScopeAmendment <amendment.json> `
  -OutPath <project-root>\morphospace\receipts\<amendment-id>.json |
  ConvertFrom-Json
```

Review the reported action, path, and SHA-256, then replay the exact input hash:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action AmendActiveWriteScope `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -ActiveWriteScopeAmendment <amendment.json> `
  -ExpectedActiveWriteScopeAmendmentSha256 $plan.audit_receipt.sha256 `
  -OutPath <project-root>\morphospace\receipts\<amendment-id>.json `
  -Execute
```

Execution installs the exact amendment input as the receipt and atomically
updates only the unit's `allowed_repositories`, `state.last_event_id`, and the
event ledger. The transition ledger carries `project.spec.json` as an unchanged
v3 projection so its authority is checked again under the workspace mutex.

The action never edits project scope, feature locks, other unit fields, source
files, Git state, build outputs, validation evidence, devices, or remotes. If
project authority must grow, use the separately reviewed project-scope route.
If authority, publication, or rollback ownership changes, end or supersede the
unit and author the correctly guarded successor instead.
