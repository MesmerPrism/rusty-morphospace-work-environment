# Historical Iteration-Unit Adoption

## Decision

Current and future iteration units remain closed against the portable workflow
lifecycle, project validation profiles, and current resource-kind registry.
An immutable unit already in terminal `accepted` or `blocked` state may retain
legacy vocabulary only through a project-owned
`historical_unit_adoption_receipt.v1` referenced and hash-bound by compact
workspace state.

An immutable raw `active` or `validating` unit is not terminal adoption input.
Its evolving instruction-policy diagnostics are deferred only when it is not
current or next-ready, and are discharged only after the aggregate validator
authenticates an exact canonical `<old>-superseded-by-<replacement>` event for
that same unit. Missing, malformed, ambiguous, or misbound supersession restores
the deferred errors and fails validation. Structural unit checks, closed
registries, event checks, and the one-current-unit invariant are never deferred.

## Contract

Each receipt binds the project, source workflow release and commit, and every
adopted unit by ID, project-relative path, complete-file SHA-256, exact terminal
status, terminal event/evidence, and exact normalization mappings. Unknown
legacy categories and profiles map into current portable routing semantics;
their original domain meaning remains visible as a tag or limitation. Mappings
must cover exactly the unknown values—neither missing nor extra entries pass.

The one retired terminal publication-accounting mode may map from
`publication` to current `feature` semantics for a blocked unit only. That
mapping neither adds a current work mode nor reclassifies current work. It
additionally binds the exact terminal event-line SHA-256 and terminal
validation-receipt SHA-256; the compact-state reference hash-binds the adoption
receipt, forming one exact state-to-receipt-to-terminal-evidence chain.

Resource kinds may use a `null` current target only for historical-only,
non-executable semantics. This preserves old observation evidence without
claiming a current isolation or lease contract. In particular, an old
`network-interface` noun does not become a current portable resource kind.

An immutable terminal unit may also retain a formerly valid instruction-impact
decision and instruction-surface actions. The receipt maps the exact legacy
impact to `update` and names every affected agent, README/router, or skill path
whose historical `review-no-change` action now requires `update`. These
mappings must cover exactly the current semantic mismatches; missing, extra,
renamed, or action-drifted surfaces reject. A blocked unit may retain a
historical `planned` status: action normalization does not mark a surface
complete or claim that an instruction edit or validation command ran. The unit
and its historical instruction bytes remain unchanged, and current or future
units cannot use this route.
Any instruction-impact or surface-action mapping also binds exact terminal
event-line and receipt hashes.

A narrower terminal-blocked projection covers a required skill surface that is
wholly absent from the immutable unit bytes. The receipt lists every and only
the skill IDs currently required by the unit's triggered change categories,
using each exact canonical `<skills-root>/<skill-id>/SKILL.md` path. Validation
projects `action: update` while retaining `status: planned`; the historical unit
still contains no such surface, and the receipt claims no instruction edit,
completion, or validation execution. Exact unit bytes, blocker event-line hash,
and terminal receipt hash are mandatory. This route rejects accepted,
current/in-flight, optional, extra, already-present, renamed, or non-`update`
surfaces.

A separate accepted-only projection covers a current required skill route that
did not apply when the exact historical unit was accepted. The receipt lists
every and only the wholly absent current skill IDs and canonical paths, records
the current `update` requirement, and fixes the terminal requirement to
`not-required-at-acceptance`. It does not synthesize a surface, mark one
complete, or claim a historical edit or execution. Exact accepted unit bytes,
accepted event-line hash, and passing validation-receipt hash are mandatory.
Current, blocked, in-flight, optional, extra, already-present, renamed, or
non-passing evidence rejects.

A terminal blocked validation unit may replace a formerly broad read-only
dependency directory only in the current validation view. Its receipt binds a
portable exact-closure artifact and maps every and only the immutable rows that
no longer fit current project scope. Each target must be a nonempty exact
current project path, a strict descendant of the original row, and the complete
set of closure leaves attributed to that row. Repository identities, unit
bytes, purposes, verification commands, and every already-valid dependency row
remain unchanged. Optional, unrelated, broader, duplicate, colliding, renamed,
or closure-drifted targets reject.

A separate terminal blocked projection covers a planning-only scope precursor
whose declared external repository rows were consumed by completed
additions-only project-scope transactions. The receipt retains those rows as
immutable transaction declarations while the current validation view contains
only the unit's original `morphospace/` planning write scope, work mode
`validation-only`, and change category `validation`. It binds the current
project, feature-lock, and plan revisions and hashes, the exact blocker bytes,
plus each correction
receipt, ledger event, intent, completion, embedded receipt bytes, and strict
chronology. The added paths must exactly equal the retained historical row and
the correction's after-set must remain contained in current project scope. Git,
device, and remote mutation claims are fixed false.

Work-mode adoption changes only current validation projection. It does not
complete a surface, accept a unit, execute a command, or prove publication.

## Fail-Closed Boundary

Validation rejects receipt-reference hash drift, unit-byte drift, changed
status, missing or duplicate units, duplicate or invalid mappings, missing or
drifted terminal evidence hashes, unknown normalized targets, incomplete
work-mode or instruction-impact or surface-action coverage, incomplete or
extra missing-skill or later-required-skill or dependency-scope coverage,
overlap between blocked and accepted missing-skill projections, closure or
project drift, missing scope-correction evidence, transaction or chronology
drift, retained write authority, and adoption by a current or future unit.
Superseded-unit instruction debt rejects unless the exact canonical event
projection is authenticated. Removing
the receipt restores strict current validation; it never creates an ambient
compatibility mode.

Historical unit files and event lines remain byte-unchanged. A project adds
only the receipt and compact-state reference. The receipt conveys workflow
validation semantics only; it cannot alter runtime, activation, repository
scope, device behavior, Git authority, or downstream lane authority.

If the compact-state receipt hash is already damaged, do not change that
reference. Record the expected and observed hashes, add a separately named
independent reconstruction with an immutable Git anchor, and add one
`historical_unit_adoption_reconstructions` state reference. The projection is
current-validation-only and explicitly not the original bytes. Exact originals,
conflicting reconstructions, current/in-flight units, and accepted-evidence
rewrites reject. See
[External Planning Projection And Historical Reconstruction](EXTERNAL_PLANNING_AND_HISTORICAL_RECONSTRUCTION.md).

## Validation

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-HistoricalUnitAdoption.ps1 -SelfTest
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WorkflowContracts.ps1 -WorkspaceRoot <project-root>\morphospace
```

The focused self-test covers accepted and blocked positive adoptions, including
planned skill-action normalization, exact blocked missing-required-skill and
accepted later-required-skill projections, canonical superseded instruction
debt, exact dependency-scope and completed-project-scope projections, plus
damaged, optional-path, current-unit, transaction-drift, and over-claiming
cases.
