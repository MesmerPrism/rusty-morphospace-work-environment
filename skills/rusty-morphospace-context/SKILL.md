# Rusty Morphospace Context

Use this skill for Rusty Morphospace repo-family work: deciding which repo lane
owns a change, setting public/private boundaries, orienting a new workspace,
and routing Quest, Makepad, Manifold, Lattice, Optics, Matter, GUI, Hostess,
or public Rusty XR compatibility work.

## First Read

From the cloned work-environment repo:

1. `README.md`
2. `AGENTS.md`
3. `docs/REPO_LANES.md`
4. `docs/PUBLIC_PRIVATE_BOUNDARY.md`
5. `docs/SETUP_OVERVIEW.md`

If the task touches live Quest, ADB, APK install/launch, logcat, screenshots,
Perfetto, Wi-Fi ADB, or Meta tooling, also use `meta-quest-workflow`.

If the task asks for broad repo inventory, source-root maps, dependency drift,
or instruction-surface audits, also use `rust-work-graph`.

If the task asks for architecture, contracts, manifests, adapters,
observability, validation, or authority boundaries, also use
`system-engineering`.

## Lane Defaults

- Use Rusty Morphospace for the umbrella identity.
- Use Lattice for generic tracked-space relation work.
- Use Manifold for command, session, stream, host-manifest, and control
  transport work.
- Use Quest for Quest/Horizon/Android profiles, launch, permissions, ADB-facing
  receipts, and headset workflow.
- Use Makepad for Makepad adapters, settings surfaces, and app-shell behavior.
- Keep public Rusty XR APIs stable unless a migration is explicitly planned.

## Public Boundary

Use placeholders in portable docs:

- `<workspace-root>`
- `<repo-root>`
- `<android-sdk-root>`
- `<android-ndk-root>`
- `<jdk-root>`
- `<openxr-loader-so>`
- `<quest-serial>`
- `<package>`
- `<activity>`
- `<path-to.apk>`

Do not commit local paths, private repo names, package identities, device
serials, generated APKs, signing material, screenshots, logcat, Perfetto
traces, captures, pairing material, or private app payloads.

## Extraction Rule

References and app code are design pressure, not source templates. Extract:

- vocabulary;
- failure modes;
- interface boundaries;
- fixture shapes;
- validation discipline.

Do not extract:

- private semantics;
- package identities;
- SDK/tool caches;
- generated artifacts;
- runtime dependencies without a license and provenance pass.

Add public reusable work as contracts, schemas, deterministic helpers,
synthetic fixtures, and source examples before adapters.
