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
| `meta-quest-workflow` (canonical source: `meta-quest-agent-workflow`) | Device policy, provider selection, ADB, APK, runtime validation, QCL, sidecar, capture, signal, or evidence rules change. | Typed-provider preference, fallback labels, device-operation gates, stop rules, evidence boundary, and links. |
| `rust-work-graph` | Repo inventory, source roots, module layout, instruction-surface audits, graph cadence, or impact analysis changes. | Scan order, graph interpretation rules, scope limits, and links. |
| `<planning-root>/AGENTS.md` | Machine-local read order, lane defaults, public/private strategy, validation tiers, or autonomous workflow policy changes. | Compact state read order, required skills, durable defaults, and links. |
| `<repo-root>/AGENTS.md` | The touched repo's authority, source map, module layout, activation, validation, or platform boundary changes. | Repo-local ownership, validation commands, source routing, and links. |
| `<repo-root>/README.md` or nearest router doc | Contributor workflow, public contract, setup, module placement, or validation entrypoint changes. | User-facing first path, supported surface, and links to deeper docs. |

Only skills relevant to the change category need updating. The lifecycle
manifest provides the minimum skill routing used by validation; a unit may add
more surfaces when its scope crosses multiple concerns.

## Iteration-Unit Record

Every unit declares:

- `change_categories`;
- `instruction_impact`: `none`, `review`, or `update`;
- `instruction_surfaces`, each with kind, path, owner, change reason, action,
  status, validation, and a skill ID when the surface is a skill;
- `instruction_none_justification` when impact is `none`.

Surface kinds distinguish concise entrypoints (`agents`, `readme`, and
`router-doc`), detailed validation routing (`validation-doc`), and installed or
portable skills (`skill`). A validation document does not substitute for the
required README or router entrypoint.

Changes to authority, module layout, feature activation, validation, device
policy, repo routing, or public/private boundaries require `update`. Before
such a unit can become `accepted`, the nearest repo `AGENTS.md`, a README or
router doc, and every relevant skill named by the synchronization matrix must
have complete update records.

The sole current-unit exception is an explicitly declared
`work_mode: validation-only` unit. It changes no product or reusable workflow
behavior, uses `instruction_impact: review`, and records each routed AGENTS,
README/router, validation document, and skill surface as `review-no-change`.
Discovering a needed content change ends that unit; it does not convert the
review record into an update claim.

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

Stable module promotion also includes the `instruction-sync` gate.
