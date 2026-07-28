# Prepared Publication Reconstruction

`prepared_publication_reconstruction.v1` closes stale prepared-bundle
bookkeeping when every distinct prepared revision is now ancestor-or-equal to
the current intended remote ref but the immutable PreparePush owner still says
`execution: not-performed`.

Use `ReconcilePreparedPublication`; retirement instead requires at least one
distinct prepared revision to be unreachable. Planned accounting requires an
executed-push receipt, and unplanned closure requires publication before
preparation.

The input hash-binds the exact repository-map bytes, PreparePush owner and named `push_plan`, prepared
intent/completion/event, accepted unit and passing validation, canonical
pending bundle and blocker, logical legs, and collapsed physical remote/refs.
This v1 action is intentionally single-unit: `unit_ids`, the pending bundle,
the immutable plan, the selected `-UnitId`, and the one hash-bound accepted
unit must all identify that same exact unit. Multi-unit reconstruction needs a
separately versioned contract with one complete acceptance chain per unit.
The passing validation receipt must satisfy the complete v1 schema and bind to
both its validation-pass transition and the acceptance transition that produced
the exact accepted unit bytes. Each prepared, validation, and acceptance
transition must use canonical ledger paths and roles, authenticate its complete
intent/completion hashes and target state/unit hashes, and equal exactly one
ordered event in a strict-UTF-8, duplicate-key-rejecting
`iteration-events.jsonl` with the correct preceding event tail. Intent and
completion container timestamps must use the authoritative seven-digit UTC
form, and every transition artifact must have a canonical path, lowercase
SHA-256, canonical base64 payload, and matching decoded hash. The prepared
transition must own exactly one artifact whose path, hash, decoded bytes, and
byte content equal the retained PreparePush owner snapshot. The embedded
plan's `prepared_at` must equal the authoritative PreparePush event timestamp.
Every ledger event from validation through preparation must have its complete
transition pair hash-bound by the input. The named validation, acceptance, and
prepared transitions plus the ordered `intervening_transitions` inventory must
cover that segment exactly. Each transition's pre-state and pre-unit hashes
must equal the preceding transition's completion hashes; event ordering alone
is not continuity. When validation is not the first ledger event, the input
must also hash-bind its exact adjacent `validation_predecessor` transition and
that transition's completion hashes must equal validation's pre-state and
pre-unit hashes. With no intervening event this requires direct
validation-to-acceptance and acceptance-to-preparation equality.

Physical refs are derived from the immutable plan plus the hash-bound repository
map. Every
logical plan leg appears exactly once. Aliases collapse only when resolved
physical repository identity, intended remote, intended merge ref, prepared revision,
branch, and upstream are identical; split, merged, duplicate, unused, or
substituted refs reject. Live branch, upstream, remote, and remote ref are
revalidated without making historical actor, time, order, or force claims.
`active_workspace_observation.repositories` is non-evidentiary context only.
It is limited to 128 closed, sanitized `{repo_id, relation, dirty}` records;
`relation` uses the contract's fixed vocabulary and `dirty` is a boolean or
`null` when it cannot be observed. Paths, branch names, revisions, remote
identities, and free-form payloads are not admitted, and the list may be empty.
Every physical ref retains the resolved fetch and push remote identity hashes;
both must match the observations and each other, so this v1 route does not
admit split fetch/push endpoints.
Each physical ref enumerates the complete ordered `prepared..tip` history with
full revisions, parents, trees, and changed paths. Active worktrees are
non-evidentiary; Git proof comes from independent clean readback clones whose
canonical worktree root is the mapped path and whose Git directory is its own
repository-owned `<readback-root>/.git` common directory. Physical directory IDs and final filesystem paths bind each
worktree root, Git directory, common directory, and object directory. Reparse
points, short-name aliases, linked worktrees, alternate/shared object databases,
external separate Git directories, replacement refs, legacy grafts, shallow
history, Git environment overrides, physical observation aliasing, dirty or
divergent checkouts, and readback worktree/Git/object storage overlapping the
active workflow workspace or its owning Git repository reject. Every object
graph command runs with replacement objects disabled. Two complete observations must match exactly across
those physical identities plus worktree root, Git ownership, HEAD, branch,
upstream, upstream tip, ahead/behind counts, cleanliness, and fresh remote tip.
The resolved fetch and push remote URL identities are captured in both
observations, so retargeting a named remote to a distinct same-tip repository
also rejects. Each observation resolves and pins its fetch endpoint before
`ls-remote`, performs the readback against that endpoint rather than the mutable
remote name, and then rechecks both name-to-fetch and name-to-push mappings;
an intra-observation retarget therefore cannot substitute another endpoint.
The final mutex-protected admission also compares the exact validated
event-ledger bytes, byte length, and SHA-256 before passing that same binding to
the transition ledger; retaining only the same tail identity is insufficient.

Claims about original execution, cross-repository order, planning-last
execution, force/no-force history, actor/time, and historical non-publication
are false. Input, repository-map, and evidence documents are each read once
into bounded strict-protocol snapshots while read leases remain held through
admission; parsing and hash verification use those exact same bytes.
Immediately before transaction admission, under the same workspace mutex that
guards the state/unit/event-tail CAS, execution repeats the complete Git
observation, byte-compares every retained snapshot to its path, re-authenticates
the exact ledger events, and repeats the standalone and event-bound conflict
search, including competing reconstruction or retirement evidence. The
derived event ID, timestamp, transaction ID, output path, iteration event, and
automation result are schema/portability validated before the mutex-protected
mutation route begins. The
transaction receives the retained input bytes in memory rather than reopening
the path, clears only matching bookkeeping, and appends
`prepared-publication-reconstructed`.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Invoke-WorkUnitAutomation.ps1 `
  -Action ReconcilePreparedPublication `
  -WorkspaceRoot <project-morphospace-root> `
  -UnitId <accepted-unit-id> `
  -RepoMapPath <clean-readback-repository-map.json> `
  -PreparedPublicationReconstruction <path-to-input-evidence.json> `
  -OutPath <project-morphospace-root>\receipts\<reconstruction-id>.json `
  -Execute
```
