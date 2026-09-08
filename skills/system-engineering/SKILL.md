---
name: system-engineering
description: 'Guide Rusty Morphospace architecture across repositories: authority boundaries, contracts, interfaces, validation, and maintainable handoff surfaces.'
---

# System Engineering

Use this for cross-repository architecture and system decisions. Keep project
state, machine paths, and private evidence in their owners.

## Locate the contract

When installed, read `references/local-work-environment.json` before following
work-environment documentation. If absent, use an explicit
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone; never guess paths.
Read the target project's nearest instructions and, for ordinary continuation,
`<work-environment>/docs/CURRENT_WORK_VALIDATION.md`. Current unit scope,
authenticated transactions, and explicit prerequisites remain strict; retired
history is an audit concern unless explicitly selected.

## Design rules

- Assign every runtime parameter and state transition to one accountable owner.
  Adapters translate requests and expose effective readback; transport alone is
  not acceptance.
- Separate control surfaces from high-rate media, pose, depth, mesh, camera,
  particle, and GPU-buffer data. Keep UI and CLI as adapters into the same
  owner.
- Bind cross-repository work to exact source identities. Treat project specs,
  feature locks, and runtime receipts as the declared composition contract.
  Keep reusable modules behind a neutral conformance harness or independent
  consumer, and keep app or device details in adapters.
- Derive validation from the current unit and keep pass evidence, acceptance,
  publication, and device evidence distinct. Preserve blockers and dirty or
  historical bytes; do not rewrite them to repair an audit.

For substantial work, state the decision, scope, ownership, interfaces,
observability, validation, risks, and next slice in proportion to the change.
Use the resolved owner runbooks for explicit historical recovery or migration:
`docs/HISTORICAL_UNIT_ADOPTION.md`,
`docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md`, and the relevant
linked contract. Route live Quest or ADB/APK work to `$meta-quest-workflow`.

This guidance does not authorize repository mutation, publication, device work,
credentials, or access to private material.
