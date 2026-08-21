# Active Unit Contract Correction

`CorrectActiveUnitContract` is the narrow owner transaction for one exact
current `active` feature unit whose contract has a legacy string or absent
`architecture_decision` and wholly omits the two currently required
`rusty-morphospace` and `system-engineering` skill surfaces. It is not a
generic unit editor, instruction-completion route, or historical projection.

Use it only after the project owner has determined that the unit is still the
exact current feature unit and that ordinary actions cannot represent this
schema-only repair. A validating, ready, terminal, non-current, validation-only,
or scope-changing unit is rejected.

## Exact Correction Contract

Start from
[`active-unit-contract-correction.example.json`](../templates/active-unit-contract-correction.example.json)
and validate it against
[`active-unit-contract-correction-v1.schema.json`](../schemas/active-unit-contract-correction-v1.schema.json).
Keep the project-specific correction input in the adopting project's private or
ignored control area. The action atomically installs those exact input bytes as
the project-owned receipt.

The correction compare-and-swap binds:

- exact project ID, revision, and canonical SHA-256;
- exact current active feature-unit ID and status;
- canonical workspace-state SHA-256;
- both raw-byte and canonical JSON SHA-256 identities of the current unit; and
- exact event-ledger byte SHA-256, length, and tail event ID.

If the old architecture decision is a string, `architecture_decision.selected`
must retain it verbatim. The target is always the exact four-field object
`selected`, `material_advance`, `deferred`, and `deferred_reason`; all four are
non-empty bounded strings. A missing decision may supply `selected` directly.
An existing object, null, empty, or other legacy shape is rejected.

The only added instruction records are the fixed, ordered
`rusty-morphospace` and `system-engineering` skill surfaces. Both use the
canonical `<skills-root>/<skill-id>/SKILL.md` path,
`review-no-change`, and `planned`. The current-unit rule is rechecked before
the transaction: the unit must be the current feature unit, those skill paths
must be outside its writable scope, and the current lifecycle routing result
for its unchanged categories must be exactly those two skills. This is a
semantic routing equivalence, not a category allowlist: authority and
public/private-boundary categories receive no general exemption. Any extra,
reordered, duplicate, non-required, non-canonical, writable, or already-present
skill surface rejects.

The target unit must satisfy the current iteration-unit schema and current
required-skill-surface rules before mutation. The action preserves every other
unit field, including repository/path scope, source composition, guard/risk and
work modes, objective, acceptance/validation, existing instruction records,
commit/publication policy, and project authority. It preserves workspace state
except `last_event_id` and preserves the entire existing ledger prefix.

## Two-Phase Invocation

First prepare a non-mutating plan:

```powershell
$plan = pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectActiveUnitContract `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <active-feature-unit-id> `
  -ActiveUnitContractCorrection <private-correction-input.json> `
  -OutPath <project-root>\morphospace\receipts\<correction-id>.json |
  ConvertFrom-Json
```

Review that `executed` is `false`, all preservation flags are `false`, and
`audit_receipt.sha256` is the exact correction input SHA-256. Then replay that
hash for the explicit owner transition:

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action CorrectActiveUnitContract `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <active-feature-unit-id> `
  -ActiveUnitContractCorrection <private-correction-input.json> `
  -ExpectedActiveUnitContractCorrectionSha256 $plan.audit_receipt.sha256 `
  -OutPath <project-root>\morphospace\receipts\<correction-id>.json `
  -Execute
```

Execution uses the workspace mutex and transition ledger. It rechecks the
canonical unit/state/ledger CAS, unit raw-byte CAS, and unchanged project
projection before it records one intent, one completion, one correction receipt,
and one appended event. Existing outputs, event replay, stale bindings, and
transaction faults fail closed.

The correction does not run validation, complete instruction surfaces, create
or modify a Git worktree, build, contact a remote, touch a device, accept the
unit, or authorize publication. After a successful correction, the ordinary
`CompleteInstructionSurfaces` action separately observes and completes the
planned skill records; validation and acceptance remain separate owner actions.

Run `scripts/Test-CorrectActiveUnitContract.ps1 -SelfTest` after changing this
action, its transaction binding, schema, template, or routing surface.
