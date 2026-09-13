# Preparation completion timestamp recovery

`RecoverPreparationCompletionTimestamp` repairs one evidenced chronology
defect without rewriting the original preparation record. A preparation can
have an intent timestamp later than the wall-clock timestamp previously used
by its completion writer. Ordinary current-work validation rejects that
ordering, even when admission and claim subsequently completed.

The supported retained shape is one preparation followed by exactly its
ordinary admission, Ready and Claim transactions. A different or damaged
suffix needs its own evidenced owner repair; this action cannot skip it.

Use the preparation-specific request builder to observe and bind the original
intent, completion, preparation receipt, source lock, repository map, retained
ledger prefix and subsequent owner transactions. Review the exact request and
execute it through `Invoke-WorkUnitAutomation.ps1` using the expected request
SHA-256. The builder uses the actual current time; do not invent a later
timestamp to repair an earlier one.

The recovery authenticates every other preparation and continuation predicate.
It appends its own transaction, event and receipt and advances the current
event pointer. It preserves project, feature lock, source composition, old
intent/completion, unit and source bytes. It does not change the current unit,
validate implementation, accept a candidate or grant publication or device
authority.

The current-work reader accepts the original chronology defect only through
that exact authenticated correction. Missing or damaged evidence, a different
defect, stale state or a conflicting suffix still rejects. Replays reuse the
original transaction; they do not create a generic chronology exemption.

New preparation completions use a timestamp no earlier than their intent.
This prevents recurrence while keeping the strict reader and all original
evidence intact. Ordinary callers should omit optional timestamp overrides.

Run the focused preparation timestamp recovery check, including a positive
fixture built through owner actions, preserved-byte checks, damaged bindings,
later continuation, interruption and exact replay. Candidate-side tests are
dynamic evidence; adopt the reviewed owner revision before recovering a real
project through this new action.
