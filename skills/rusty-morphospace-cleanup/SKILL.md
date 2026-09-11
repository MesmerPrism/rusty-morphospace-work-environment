---
name: rusty-morphospace-cleanup
description: Run a user-requested manual cleanup of Rusty Morphospace generated artifacts, compact useful lessons, and establish habits that prevent new bloat. No scheduled or automatic cleanup.
---

# Manual Morphospace cleanup

Run when the user requests cleanup. This is a playbook, not a background job.
Do not schedule cleanup, run it daily, or install an on-resume cleanup hook.
Prevention during ordinary feature work is separate from deleting old outputs.

## Scope and retention

When installed, read `references/local-work-environment.json` to resolve the
current owner instructions and checkpoint; reuse the existing artifact
inventory. Start with the user's project and known generated roots. Resolve
stale routing once instead of scanning adjacent products or replaying task
history. Keep shared caches and roots with their named owners.

Use the cutoff supplied for this invocation. If none is supplied, use the
owner's declared retention window; absent one, review completed-run evidence
older than 21 days. This is an eligibility threshold during a manual request,
never a timer or automatic deletion policy. Preserve reliable date/timezone
provenance; copied directory names or mtimes alone do not establish run dates.

User authorization to clean eligible evidence replaces blanket historical
retention and repeated confirmation for compliant batches. Preserve source,
Git state, unique uncommitted work, credentials and actual non-generated inputs.
Classify contents actually found; do not invent data categories or holds from
a project name. Whole worktree/ref/history retirement is separate scope.

## Manual pass

1. Shortlist known owned caches/intermediates **and** old APK/run/test evidence.
   Mark each candidate delete, archive, retain with a current reason, exclude
   with the actual owner/type, or unreviewed. Finish the bounded unreviewed set;
   cache-only deletion does not complete evidence cleanup. Zero eligible is a
   valid result. No full-drive search is needed to increase the total.
2. Identify the working candidate and last accepted baseline separately. Record
   existing durable commits; checkpoint relevant uncommitted/untracked source
   and compact lessons with focused local commits within user authority. Stage
   specific paths, preserve unrelated work and existing refs; no empty commit
   or push is needed. If a source lock or concurrent work prevents committing,
   preserve unique changes in a recoverable patch/checkpoint and report that
   exception; unrelated eligible cleanup continues. Preserve lasting facts in
   an existing owner note: source identity, result, lesson, limitation and next
   action. A checkpoint is source preservation, not feature acceptance. Do not publish
   unrelated/private work or put bulky binaries in ordinary Git. Historical
   acceptance alone is not a raw-artifact hold. A hold names the current
   consumer and release/review condition. Current validator-bound evidence and
   protected append-only/immutable packages need their owner migration route;
   defer those exact paths while other cleanup continues.
3. Archive only valuable material whose originals still matter. Verify the
   archive and keep a small purpose/contents/source/restore index. Otherwise
   retain the useful summary and delete the bulk. Do not ZIP everything. Git
   source does not guarantee identical APK bytes or replay a device observation;
   state when raw proof is retired. A move within a volume is not freed space.
4. Prepare one compact exact batch: resolved paths, age basis, measured logical
   bytes, decision and retained references. Record free space **before** deletion
   and the actual small manifest/helper identities if used. Missing observations
   stay unknown; later corrections are not proof of what previously executed.
   Ordinary caches need proportionate source/age/use checks, not a historical
   release audit or per-file proof archive.
5. Recheck resolved containment through ancestor links/reparse points, relevant
   identity, and source/build-root activity. A target-subdirectory command-line
   search alone does not prove idleness. Before exclusive apply, follow the
   contributor or project's configured exclusive-resource coordination. Use
   native PowerShell literal-path operations; never broad `git clean`,
   force reset, cross-shell deletion, or recursive worktree/parent removal.
   Skip busy/changed targets. Release the lease even if reporting fails.
6. Verify removed targets and retained references, measure free space again,
   and keep one short closure. Separate logical bytes removed from volume delta
   and concurrent I/O. Keep original facts distinct from corrections. No old APK
   rebuild or device run is needed just to justify cleanup.

Prefer existing tools or a small reviewed manual batch. Do not create a new
framework, schema or worktree by default. If a one-shot helper is necessary,
disable its Apply entrypoint after completion. A recreated path or new batch
needs fresh review; old manifests never grant continuing deletion authority.

## Prevent bloat during normal work

- Pick an owned output root and distinguish scratch, reusable cache, current
  candidate/reference and diagnostic evidence before producing large outputs.
- Capture only what answers the current check. Bound noisy logs, trace duration
  and recordings at creation. Keep concise outcomes; capture full diagnostics
  when an actual failure/question warrants them.
- Keep one authoritative APK/bundle and reference it across reports. Reuse
  valid warm caches; preserve required branch/source/toolchain separation.
  Do not copy binaries into every test folder or destroy caches every pass.
- At useful checkpoints, consolidate lessons in existing notes, keep current
  artifact consumers explicit, and mark obsolete outputs for the next manual
  cleanup. Tidy scratch created and owned by the current task as part of normal
  task completion; do not use that as a trigger to purge historical outputs.
- Keep latest-state notes small; replace routine summaries where permitted.
  Respect protected ledgers. Put output limits and regeneration commands in
  owner instructions; shared cache/output-policy changes go to their owner.

## Closeout

Report scope, deleted/archived totals, remaining holds/unreviewed work, lessons,
and any small prevention change. Reference exact details instead of repeating
them. Report cross-project ownership or shared-contract impacts through the
existing coordinator; ordinary owned cleanup needs no extra coordination unit.
Use the actual supported validation command; workflow-only flags do not belong
on unrelated product checkers. Respect a user pause at completion.
