# Instruction Synchronization

Agent entrypoints must stay aligned with the architecture they route. Record
instruction impact in every iteration unit and update the smallest relevant
surfaces in the same unit. Keep `AGENTS.md`, `SKILL.md`, and README entrypoints
concise; link to detailed runbooks instead of copying long recipes into them.

## Synchronization Matrix

| Surface | Update when | Keep in the entrypoint |
| --- | --- | --- |
| `rusty-morphospace` | Public repo lanes, naming, project/module lifecycle, feature activation, validation selection, agent routing, or public/private rules change. | Portable first-hop routing and links to detailed skill references. |
| `rusty-morphospace-context` | Machine-local work-environment resolution or installed provenance routing changes. | Explicit locator read, portable-skill handoff, and authority limits. |
| `system-engineering` | Authority, contracts, manifests, module kinds, observability, validation gates, or mitigation structure changes. | Architecture questions, invariants, output shape, and links. |
| `meta-quest-workflow` (canonical source: `meta-quest-agent-workflow`) | Device policy, provider selection, ADB, APK build lane, runtime validation, QCL, sidecar, capture, signal, or evidence rules change. | Typed-provider preference, build-lane and fallback labels, device-operation gates, stop rules, evidence boundary, and links. |
| `rust-work-graph` | Repo inventory, source roots, module layout, instruction-surface audits, graph cadence, or impact analysis changes. | Scan order, graph interpretation rules, scope limits, and links. |
| `<planning-root>/AGENTS.md` | Machine-local read order, lane defaults, public/private strategy, validation tiers, or autonomous workflow policy changes. | Compact state read order, required skills, durable defaults, and links. |
| `<repo-root>/AGENTS.md` | The touched repo's authority, source map, module layout, activation, validation, or platform boundary changes. | Repo-local ownership, validation commands, source routing, and links. |
| `<repo-root>/README.md` or nearest router doc | Contributor workflow, public contract, setup, module placement, or validation entrypoint changes. | User-facing first path, supported surface, and links to deeper docs. |

Only skills relevant to the change category need updating. The lifecycle
manifest provides the minimum skill routing used by validation; a unit may add
more surfaces when its scope crosses multiple concerns.

A portable APK build-lane change normally updates the Meta workflow's focused
playbook, `AGENTS.md`, README/router, and canonical skill together with this
repository's Quest workflow, project-isolation, and concise entrypoints.

## Iteration-Unit Record

Every unit declares:

- `change_categories`;
- `instruction_impact`: `none`, `review`, or `update`;
- `instruction_surfaces`, each with kind, path, owner, change reason, action,
  status, validation, and a skill ID when the surface is a skill;
- `instruction_none_justification` when impact is `none`.

Surface kinds distinguish concise entrypoints (`agents`, `readme`, and
`router-doc`), detailed validation routing (`validation-doc`), compatibility
and roadmap records (`compatibility-doc` and `roadmap-doc`), and installed or
portable skills (`skill`). Compatibility, roadmap, and validation documents do
not substitute for the required README or router entrypoint.

Changes to authority, module layout, feature activation, validation, device
policy, repo routing, or public/private boundaries require `update`. Before
such a unit can become `accepted`, the nearest repo `AGENTS.md`, a README or
router doc, and every relevant skill named by the synchronization matrix must
have complete update records.

Validation-authority promotion additionally updates the detailed validation
runbook. It distinguishes current-delta evidence from scheduled Deep history,
records artifact/reuse invalidators, and treats `pending-infra` as a
non-promotional operational state. It never converts a candidate receipt into
acceptance or publication authority.

An idle-project envelope is a project-level authority change: document the
preparation action, then require later unit admission to bind its receipt and
source lock. A preparation receipt never itself authorizes a future unit,
source mutation, build, device operation, or publication.

History archive/checkpoint changes update the detailed archive runbook, the
affected-validation runbook, README/router, and the routed project-workflow
reference. The documented route must preserve raw historical bytes, keep
historical-debt baselines separate, and distinguish Quick checkpoint/tail
integrity from Deep/audit/migration archived replay. Candidate evidence remains
dynamic only and does not replace the external validation-authority boundary.

An explicitly declared `work_mode: validation-only` unit changes no product or
reusable workflow behavior, uses `instruction_impact: review`, and records each
routed AGENTS, README/router, validation document, and skill surface as
`review-no-change`. Discovering a needed content change ends that unit; it does
not convert the review record into an update claim.

A second, closed explicit-feature compatibility rule applies while a feature
unit is proposed, ready, active, or validating. It permits exactly the
currently lifecycle-routed `rusty-morphospace` and `system-engineering` skill
surfaces to remain `review-no-change` only when every other instruction surface
uses `update`, the routed-skill union is exactly that pair, and the local
repository map registers their canonical `<skills-root>/<skill-id>/SKILL.md`
files under one distinct external `skill-surfaces` source. The alias set is
exactly `skills-root`; each installed file must SHA-256 match this revision's
tracked `skills/<skill-id>/SKILL.md` router file; and the resolved skill root
must neither equal, contain, nor be contained by a writable mapped repository.
Ready, Inspect, and Claim use that bound preflight as admission authority.
Mapless aggregate/current-unit compatibility remains diagnostic-only and cannot
Ready or Claim; aggregate fixtures that supply a repository map apply the same
trusted-byte rule. An extra alias or skill, wrong category, unresolved alias,
path-shaped or byte-different lookalike, writable/overlapping skill root, or
update outside the declared repository write scope fails closed. This rule
does not apply to accepted, blocked, superseded, or other historical units and
does not reclassify their diagnostics.

An immutable unit that predates `work_mode` may retain a completed relevant-
skill `review-no-change` only when the append-only ledger proves that unit is
accepted, blocked and no longer current with a blocker as its latest event, or
superseded by the validator's canonical legacy old-to-replacement event
projection. This compatibility does not upgrade that legacy projection to a
current transaction-authentication claim, authorize a new transition or
repair, or apply to a unit with explicit `work_mode`. Current and future
feature units must update every relevant skill. Other formerly valid
instruction metadata may be projected only through the exact hash-bound
historical-unit adoption contract, which does not relax synchronization for
a current or future unit. See
[Historical Iteration-Unit Adoption](HISTORICAL_UNIT_ADOPTION.md).

Aggregate validation may defer evolving instruction-policy failures for a raw
active/validating unit only when it is neither current nor next-ready. The
failures disappear only after the same pass authenticates that unit as the old
endpoint of an exact canonical supersession event. An accepted unit that wholly
omits a skill route introduced later needs an exact project-owned
`later_required_skill_surfaces` adoption entry; the entry records
`not-required-at-acceptance` and never fabricates completion.

## Cadence

1. Declare instruction impact when the unit becomes `ready`.
2. Update instruction entrypoints with the implementation slice that makes
   them true, or before accepting that slice.
3. Keep recipes in detailed docs or runbooks; add only durable routing to
   `AGENTS.md` and `SKILL.md`.
4. Run workflow-contract, public-boundary, link, and repo-owned validation.
5. For receipt-security workflow changes, verify installed/portable skill
   parity and bind the quick-contract, capsule, child-host preflight,
   nonce-bound record, typed-failure, and cache-invalidation rules explicitly.
5. Mark surfaces complete and append an iteration event before acceptance.

External-owner-gate review for this authority change updated `AGENTS.md`, the
README/router, the detailed external-validation runbook, and the three routed
portable skills. No Meta Quest workflow change applies because the gate cannot
execute candidate code or authorize a device operation.

Stable module promotion also includes the `instruction-sync` gate.

When immutable adopted history has separately classified diagnostics, validate
the exact current unit's instruction contract without rewriting or waiving that
history:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot <workspace-root> `
  -CurrentUnitInstructionOnly
```

This narrow gate validates the current unit schema, closed surface-kind set,
required entrypoints and routed skills. It intentionally does not inspect,
normalize, or claim a pass for historical units; the aggregate contract remains
the separate historical diagnostic.
