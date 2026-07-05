# Workflow And Environment Dependency Audit

Status: initial portable baseline.

## Decision

Create a dedicated Rusty Morphospace Work Environment repository that carries
portable onboarding docs, manifests, validation scripts, and local-skill
templates. It should not copy private planning state or machine-specific
receipts. It should give a new contributor enough structure to install tools,
clone source repos, install local skills, build public examples, and run Quest
APK workflows with explicit placeholders.

## Sources Audited

| Source family | Reusable extraction | Excluded from this repo |
| --- | --- | --- |
| Morphospace planning instructions | Lane naming, state-first workflow, split pressure, public/private boundary, tiered validation. | Local absolute paths, branch hygiene receipts, private repo names, raw planning ledgers. |
| Local skill files | Four skill templates: Morphospace context, system engineering, Rust work graph, and Meta Quest workflow. | Machine-specific script paths and private project details. |
| Rusty XR public docs | Android toolchain split, public extraction gates, APK build examples, Quest shell checklist, OpenXR bring-up lessons. | Public repo generated APKs, private downstream package names, local loader paths, live evidence. |
| Meta Quest agent workflow | Device-operation discipline, ADB install/launch/logcat patterns, capture taxonomy, provider model. | A bundled copy of Meta tools, ADB, SDKs, screenshots, or logs. |
| Quest Termux Lab | Termux sidecar authority model, loopback Wi-Fi ADB gate, on-device APK lab path, public-safe evidence discipline. | Live endpoint values, pairing material, generated APKs, helper-app private package details. |
| Rust work graph practice | Start broad audits with tracked-file inventory; run deeper pattern scans only for scoped questions. | Generated graph outputs from one maintainer's machine. |

## Findings

The current local workflow is strong but not portable because it is encoded in
several places:

- private planning notes carry exact machine paths and branch state;
- local skills know local repo roots and local scripts;
- Quest APK procedures are split across public Rusty XR, local planning notes,
  public Meta Quest workflow, and Termux sidecar notes;
- dependency setup is implicit in shell history and local environment variables;
- contributors need a safe way to install skills without copying raw private
  context.

The reusable content is mostly process and contract discipline:

- concrete repo lanes and ownership boundaries;
- dependency matrix and environment variables;
- public extraction gates;
- Quest device-operation gates;
- Termux sidecar authority limits;
- tiered validation and graph inventory defaults;
- local-skill installation pattern.

## Portable Repo Architecture

This repo owns onboarding and agent setup. It does not own runtime behavior.

| Area | Owner in this repo | Runtime/source owner |
| --- | --- | --- |
| Workspace setup | `docs/SETUP_OVERVIEW.md`, `templates/` | Contributor machine |
| Dependency list | `docs/DEPENDENCY_MATRIX.md`, `manifests/dependencies.portable.json` | Official tool installers and source repos |
| Skill templates | `skills/`, `docs/SKILL_INSTALLATION.md` | Contributor agent installation |
| Repo lanes | `docs/REPO_LANES.md`, `manifests/repo-lanes.portable.json` | Morphospace source repos |
| Quest APK workflow | `docs/QUEST_APK_WORKFLOW.md` | App shell, Rusty Quest, Rusty XR examples, Meta Quest workflow |
| Termux sidecar lab | `docs/TERMUX_SIDECAR_LAB.md` | Quest Termux Lab and live Quest workflow |
| Validation | `scripts/` and `docs/VALIDATION.md` | Contributor machine and source repos |

## Non-Scope

- Publishing or downloading generated APKs.
- Vendoring Android SDK, NDK, JDK, OpenXR loader, Meta tools, Termux APKs,
  Makepad forks, codec libraries, or signing material.
- Replacing the public Meta Quest workflow.
- Creating live device evidence.
- Moving private app payload semantics into public Morphospace docs.

## Mitigation Map

| Risk | Mitigation | Validation |
| --- | --- | --- |
| Local paths leak into public onboarding. | Use placeholders and run public-boundary scan. | `scripts/Test-PublicBoundary.ps1` |
| Skill templates become stale private forks. | Keep templates as portable routers and link to public source repos. | Review `skills/*/SKILL.md` during onboarding updates. |
| Contributors install only partial toolchains. | Maintain dependency matrix plus smoke test script. | `scripts/Test-WorkEnvironment.ps1` |
| Quest work mutates a device without clear authority. | Route live device work through `meta-quest-workflow` and serial-scoped ADB commands. | Device run evidence must name provider, goal, serial placeholder, and artifacts. |
| Termux is mistaken for shell or product authority. | Document loopback ADB gate and sidecar limits. | Require `uid=2000(shell)` gate before install/launch through Termux ADB. |
| Generic utilities get trapped in app repos. | Keep repo-lane docs and public extraction gates first-hop. | Add a contract/schema/helper before runtime adapter code. |

## Next Work

1. Replace placeholder upstream clone URLs with canonical repo URLs as public
   repos are finalized.
2. Add optional bootstrap scripts only after the dependency manifest has been
   tested on a clean machine.
3. Add source-repo-specific check recipes once each public repo's onboarding
   commands are stable.
4. Decide whether this repo should publish a release archive of skill
   templates or remain source-only.
