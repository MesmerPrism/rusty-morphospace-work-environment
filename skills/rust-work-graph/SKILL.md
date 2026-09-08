---
name: rust-work-graph
description: Map Rust workspace ownership, source roots, dependencies, instruction surfaces, and bounded refactor impact across repositories.
---

# Rust Work Graph

Use this skill to make a bounded, evidence-backed inventory or impact map
before a broad refactor, extraction, integration, or validation change.

## Establish scope

When installed, resolve work-environment docs through
`references/local-work-environment.json`. If absent, use an explicit
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone; never guess paths.
Read the target project's nearest instructions, current source composition, and
`<work-environment>/docs/CURRENT_WORK_VALIDATION.md` for ordinary continuation.
Current unit scope and exact identities remain strict; historical recovery is
separate and uses the owner runbooks, including
`docs/HISTORICAL_UNIT_ADOPTION.md` or
`docs/EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md` when applicable.

## Build the map

Start from tracked files and declared source roots. Record owner repository,
module/crate, public contract, consumers, declared dependencies, instruction
surfaces, and validation impact. Compare exact commits or trees when multiple
repositories are involved. Distinguish observations, proposals, validation,
acceptance, publication, and device evidence; do not infer one from another.

Keep private evidence, machine paths, credentials, package identities, and
device serials out of portable outputs. Route authority or contract decisions
to `$system-engineering`; route live Quest, ADB, APK, or device evidence work
to `$meta-quest-workflow`. This skill does not authorize edits, publication,
credentials, or device operations.
