# Resumable APK run transaction

Use this advisory contract when an APK workflow spans enough expensive host or
device work that an interruption should resume from retained evidence instead
of replaying every passing phase.

The fixed regular order is:

```text
host-validation -> snapshot -> build -> inspect -> install -> launch
  -> app-ready -> wearer-acceptance -> cleanup
```

The transaction manifest binds the source identity, build lane, package,
activity, and one create-new receipt leaf for every phase. Each phase receipt
binds the manifest bytes, an ordinal, the immediately preceding receipt hash,
its own evidence artifacts, result, and cleanup state. The audit accepts only a
contiguous passing prefix. It returns the first missing phase, or `cleanup`
after a post-mutation failure or a fully passing regular run.

The phase owner creates its receipt with create-new semantics after its own
checks reach a terminal result. The audit never creates receipts and never
executes a phase:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\Test-ApkRunTransaction.ps1 `
  -Path <transaction.json> `
  -ReceiptRoot <run-receipt-directory>
```

An absent receipt means the phase did not complete. A valid receipt means only
that its named owner retained hash-bound evidence; it is not permission to
repeat or skip a different phase. A non-passing phase terminates ordinary
progress. If it reports `cleanup_required=true`, only cleanup may follow; a
passing cleanup preserves the original failure. Failed or incomplete cleanup
leaves the transaction blocked.

`install` and every later passing regular phase must require cleanup. Earlier
phases may also require it when their owner created residue, and a later phase
cannot drop that obligation. Final success is possible only after all regular
phases and cleanup pass.

Keep authorities separate:

- host validation proves only its declared source/check surface;
- snapshot freezes exact source bytes but is not a build;
- build and inspection bind an APK, package, signer, SDK, ABI, and manifest;
- install proves exact installed bytes, while launch proves only Android launch
  and activity observations;
- the application proves selected runtime state and advancing semantic facts;
- wearer acceptance is explicit attended evidence when the claim requires it;
- cleanup proves restoration only for the run-owned changes it enumerates.

The generic receipt chain cannot decide whether an app-specific artifact is
sufficient. Its `does_not_prove` fields are mandatory, and existing app, File
Manager, Kiosk, Fleet, Meta Quest, validation, Agent Board, and publication
owners retain their authority. The contract authorizes no build, device, ADB,
lease, acceptance, cleanup, Git, or remote action.

Run the bounded damage suite with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\Test-ApkRunTransaction.ps1 `
  -SelfTest
```

It covers an empty run, prefix resume, pre-install blocking, post-install
failure followed by cleanup, full success, missing-phase rejection, and
predecessor, manifest, and artifact-hash tampering.
