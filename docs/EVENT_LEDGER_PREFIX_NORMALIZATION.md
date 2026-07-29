# Event-Ledger Prefix Normalization

`NormalizeEventLedgerPrefix` is a narrow workflow-owner migration for a
protocol-v2 project workspace whose otherwise strict
`iteration-events.jsonl` begins with exactly one unauthorized CRLF blank
record (`0D0A`). It is not a general blank-line compatibility mode.

Ordinary event parsing remains strict. A leading LF record, multiple leading
blank records, any interior blank record, malformed JSON, duplicate event ID,
non-contiguous sequence, regressing timestamp, wrong project identity, or
state/event-tail mismatch rejects before an intent is published.

## Authority And Effect

The action may change only:

- `iteration-events.jsonl`: remove the exact first `0D0A` bytes, preserve every
  prior event byte, and append one canonical normalization event;
- `workspace.state.json`: change only `last_event_id` to that event ID;
- one normalization receipt plus its durable intent and completion.

The current iteration-unit file is byte-preserved. Project specification,
feature lock, current-unit identity/status, repositories, Git refs, build
outputs, packages, and devices are outside this action's authority.

The typed receipt is
`rusty.morphospace.workflow.event_ledger_prefix_normalization.v1`. Its intent
retains the exact bounded preimage so recovery can authenticate both sides of
the correction. The one-MiB input bound is deliberate: larger or different
ledger damage needs a separately reviewed migration.

## Preconditions

Use a clean attached Git worktree. Record these exact current values:

- repository `HEAD`;
- raw SHA-256 of `project.spec.json`, `workspace.state.json`, the current unit,
  and `iteration-events.jsonl`;
- raw event-ledger byte length;
- current `workspace.state.json.last_event_id`.

Raw file hashes are required because Git line-ending conversion may make a
checked-out CRLF file differ from its stored blob. Do not substitute a Git blob
ID or canonical JSON hash for a requested raw SHA-256.

Plan without mutation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action NormalizeEventLedgerPrefix `
  -WorkspaceRoot <project-root>\morphospace `
  -UnitId <unit-id> `
  -LedgerPrefixNormalizationId <normalization-id> `
  -ExpectedRepositoryHead <40-character-head> `
  -ExpectedProjectSha256 <64-character-project-file-sha256> `
  -ExpectedStateSha256 <64-character-state-file-sha256> `
  -ExpectedUnitSha256 <64-character-unit-file-sha256> `
  -ExpectedEventsSha256 <64-character-event-ledger-sha256> `
  -ExpectedEventsLength <event-ledger-byte-length> `
  -ExpectedEventTailId <event-tail-id> `
  -Timestamp <strict-utc-timestamp>
```

Review the reported before/after hashes, then repeat the exact command with
`-Execute`. The action performs no Git command that changes a ref, index, or
working-tree file.

## Recovery

The intent is published before the receipt, state, or ledger changes. If an
execution is interrupted and the completion is absent, repeat the same command
with `-Execute`. Recovery admits only:

- the exact pre-state bound by the intent; or
- the exact target state bound by the intent.

Each ledger/state projection may independently be at its exact before or after
hash while a known forward repair is incomplete. Unknown bytes, repository
HEAD/branch drift, current-unit/project drift, unrelated Git dirt, damaged
transaction staging, or a second outstanding intent rejects. A committed
completion rejects replay.

The action removes only its exact transaction-owned temporary stage/backup
after hash readback. It never truncates an unknown suffix or repairs another
transaction.

## Validation

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File <work-environment-root>\scripts\Test-EventLedgerPrefixNormalization.ps1
```

The focused suite covers non-executing planning, strict ordinary rejection,
exact CRLF normalization, prior-byte preservation, state/unit isolation,
intent-stage recovery, ambiguous interruption, unrelated dirt, CAS drift,
wrong project/tail, framing variants, CLI routing, and replay rejection.

After a project executes the action, validate its normal project workflow
contracts before committing the project-owned receipt and corrected
projections. This work-environment action does not commit or publish them.
