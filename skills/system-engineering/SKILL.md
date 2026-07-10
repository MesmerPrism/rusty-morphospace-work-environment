# System Engineering

Use this skill for architecture and system-engineering work across Rusty
Morphospace repos: authority boundaries, contracts, manifests, module/plugin
boundaries, data/control/media planes, observability, validation scorecards,
reference-intake notes, and mitigation maps.

## Output Shape

For substantial architecture work, produce:

- Decision
- Scope
- Non-scope
- Authority
- Interfaces
- Observability
- Validation
- Reference Lessons
- Mitigation Map
- Next Slice

Keep the output proportional. A small code/docs change may need only a short
decision and validation note.

## Authority Rules

- One master layer owns each runtime parameter. Other entrypoints adapt into
  that layer.
- Raw adapter readback proves transport only. Acceptance needs the consuming
  runtime to report the effective value or marker.
- Low-rate profiles, Android properties, hotload files, and command payloads
  are control surfaces. Do not move high-rate camera, depth, mesh, particle,
  pose, or GPU-buffer streams into them.
- UI handlers collect parameters, invoke routes, show progress, and project
  structured evidence. They should not own hidden setup or business logic.
- Project composition uses a closed-world feature lock. Unlisted or disabled
  modules are inert and cannot change unrelated packaging or runtime behavior.
- Stable reusable modules require a second independent consumer or neutral
  conformance harness and an accepted promotion review.

## Portable Project Contracts

When a project has a `morphospace/` directory, treat `project.spec.json` as
composition authority, `feature.lock.json` as activation authority, and
`workspace.state.json` as the compact agent-resume surface. Work only within
the repository and path scope declared by the current iteration unit.

For an adopting application, require a behavior-neutral bootstrap: select its
baseline shell, record optional nearby families as disabled, assert one
unrelated feature is absent and inert, and create candidate records before
extracting reusable source.

Authority, module-layout, activation, and validation changes also have
instruction impact. Route them through
`docs/INSTRUCTION_SYNCHRONIZATION.md`; update concise routers and place long
procedures in linked docs.

## Reference Intake

When borrowing from a reference, record:

- reference name or public URL;
- why it matters;
- lesson borrowed;
- overreach rejected;
- target Rusty layer;
- validation or follow-up.

Prefer schema-only and data-only contracts before runtime dependencies.

## Validation

Validation should prove the authority boundary, not just happy-path execution.
For Quest/APK work, source/static/profile gates come before headset runs. For
public extraction, synthetic tests or fixtures come before live evidence.
