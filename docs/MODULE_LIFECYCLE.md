# Module Lifecycle

Use this lifecycle when a project-specific implementation begins to look
reusable. It prevents application assumptions from silently becoming generic
module defaults.

## Maturity States

```text
app-local
  -> candidate
  -> contract-ready
  -> adapter-ready
  -> cross-consumer-validated
  -> stable
  -> deprecated
```

| State | Meaning | Minimum evidence |
| --- | --- | --- |
| `app-local` | Implementation belongs only to its originating app. | App tests and explicit non-reuse statement. |
| `candidate` | A reusable boundary is plausible. | Candidate record, proposed lane, exclusions, provenance. |
| `contract-ready` | Neutral data and behavior are specified. | Versioned contract, valid and damaged fixtures, deterministic checks. |
| `adapter-ready` | Platform/app integration is downstream of the contract. | Adapter boundary, dependency test, effective receipts. |
| `cross-consumer-validated` | A second independent consumer or neutral conformance harness uses only the public contract. | Consumer record and conformance evidence. |
| `stable` | All promotion gates pass and rollback is known. | Accepted promotion review. |
| `deprecated` | The module has a named replacement or retirement path. | Migration and removal criteria. |

Skipping states requires an explicit promotion review explaining why the
missing evidence is equivalent. Convenience or schedule pressure is not
equivalent evidence.

## Candidate Record

Create a module-candidate record before extracting implementation. It names:

- the problem in app-neutral language;
- proposed owning lane and public contract;
- what the module owns and explicitly does not own;
- application details that must not cross the boundary;
- dependencies, provenance, license, and rejected overreach;
- originating and independent consumers;
- validation, rollback, and proposed next maturity state.

The candidate record stays useful after promotion because it preserves why
the boundary exists.

## Contract-First Extraction

1. Write the smallest versioned contract or schema.
2. Add valid, boundary, and damaged synthetic fixtures.
3. Add a deterministic conformance check.
4. Move only data-only or CPU-only helpers needed by that contract.
5. Keep platform calls, renderer ownership, package identity, permissions,
   sockets, device mutation, and private payloads in adapters or app shells.
6. Reconnect the originating app through the public contract.
7. Validate a second consumer before stable promotion.

Core modules must not gain an Android, OpenXR, renderer, media SDK, dynamic
plugin, sidecar, or app-shell dependency merely because the first application
used one.

## Leakage Review

Before promotion, reviewers answer:

- Would the contract still make sense if the originating app disappeared?
- Are names and defaults neutral rather than product-specific?
- Can a synthetic consumer use the contract without importing the app shell?
- Are permissions, routes, assets, tuning, and recovery policy downstream?
- Does every parameter have one authority owner?
- Can the module be disabled without changing unrelated packaging or runtime
  behavior?

Any `no` answer keeps the module below `stable` until resolved or explicitly
rejected in the promotion review.

## Second-Consumer Gate

The originating application does not count as its own second consumer. Stable
promotion requires either:

- a genuinely independent application or tool using only the public contract;
  or
- a neutral conformance harness that is maintained independently of the
  originating app and exercises the same public boundary.

A copied app fixture with the same hidden defaults is not independent.

## Promotion Gates

An accepted review targeting `stable` must pass:

- authority;
- contract;
- dependency;
- public boundary;
- conformance;
- negative fixture;
- second consumer;
- instruction synchronization;
- rollback.

The machine-readable gate IDs live in
`manifests/workflow-lifecycle.portable.json`.
