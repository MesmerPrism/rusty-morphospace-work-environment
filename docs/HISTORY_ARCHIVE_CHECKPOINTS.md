# History Archive Checkpoints

`ArchiveHistoryCheckpoint` is the only owner action that can add a history
archive checkpoint to an idle project. It is additive: it copies exact raw
bytes into content-addressed objects and leaves the live unit, event,
transaction, and receipt bytes in place. It never deletes, moves, rewrites,
normalizes, substitutes, accepts, builds, deploys, or publishes anything.

The request binds the current project, compact state, event-ledger byte length,
event-ledger SHA-256, exact tail event, and a canonical raw-byte source-inventory
SHA-256. The owner action requires an idle project with no current/ready unit,
blocker, pending push, nonterminal current unit, or previous archive binding.
Raw active/validating units retired by the authenticated
[current-work boundary](CURRENT_WORK_VALIDATION.md) are eligible without changing
their bytes or adding a compatibility receipt. It creates
a typed intent, raw objects, immutable root, receipt, state binding, one
appended event, and completion. A replay may continue only the same request hash
and durable intent; conflicting, interrupted, tampered, partial, reparse,
case-colliding, or source-drifted objects fail closed before state persistence.

The root records the exact `iteration-events.jsonl` prefix bytes, byte offset,
line count, tail identity, all archived source paths, and carry-forward
references held by compact state. Object names are their raw SHA-256; their
payloads are never canonicalized. The checkpoint must not be used as evidence
that a historical aggregate, acceptance, publication, source operation, build,
or device operation passed.

Quick validation checks current compact authority; the exact request, intent,
root, receipt, archive event, completion, and state/ledger-tail chain; raw
object hashes and lengths; the byte-identical ledger prefix; carry-forward
references; and the live post-checkpoint tail. An incomplete transaction,
damaged root/object/prefix/event/completion, or unresolved pre-checkpoint
reference returns `archive-replay-required`; it is not a passing Quick result.
Deep, audit, and migration select archived replay.
Historical-validation-debt baselines are separate evidence and are neither
created nor satisfied by an archive checkpoint.

Run the focused owner checks with:

```powershell
pwsh -NoProfile -File .\scripts\Test-HistoryArchiveCheckpoint.ps1 -SelfTest
pwsh -NoProfile -File .\scripts\Test-HistoryArchiveValidation.ps1 -SelfTest
```

This is a validation-authority change. Candidate tests are dynamic evidence
only; publication follows the repository's base-owned external
validation-authority and external-owner route.
