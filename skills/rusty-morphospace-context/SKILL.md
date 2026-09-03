---
name: rusty-morphospace-context
description: 'Resolve a machine-local Rusty Morphospace work-environment clone and its installed provenance before handing portable architecture, ownership, project-workflow, or boundary guidance to $rusty-morphospace.'
---

# Rusty Morphospace Context

Use this skill as the machine-local resolver when a request needs exact
work-environment provenance or paths. Do not copy portable architecture or
project-workflow guidance into this skill.

## Resolve The Work Environment

Read `references/local-work-environment.json` first. Require its exact local
work-environment root, source commit or release, dirty-source state, and docs
root. If the locator is absent, use an explicitly configured
`RUSTY_MORPHOSPACE_WORK_ENVIRONMENT` or ask for the clone location. Never guess
paths.

From the resolved clone, read the nearest `AGENTS.md` and only the public docs
needed for the request. For a project-owned `morphospace/` workspace, also read
the project's nearest instructions and compact resume surfaces in their
declared order. Treat the locator as provenance and path resolution only; it
does not own current unit, release, repository, credential, or device state.

## Hand Off

Invoke `$rusty-morphospace` for public architecture, ownership lanes, project
composition, activation, source locking, work-unit lifecycle, validation,
public/private boundaries, instruction synchronization, and agent routing.

Preserve any stricter project or planning instructions. This resolver grants
no Git publication, repository mutation, build, credential, or device
authority.
