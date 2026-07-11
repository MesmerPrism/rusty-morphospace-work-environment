---
name: rusty-morphospace-context
description: 'Use for Rusty Morphospace repo-family work: repo routing, public/private boundaries, modular extraction, cross-repo contracts, clean Matter/Manifold/Optics/Lattice/GUI/Quest/Hostess lanes, public Rusty XR compatibility, native Quest apps, legacy Makepad lanes, private proving apps, Windows operator tools, and Android companions.'
---

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

For project composition, reusable-module extraction, feature activation, or
autonomous iteration, also read:

1. `docs/PROJECT_WORKSPACE_PROTOCOL.md`
2. `docs/MODULE_LIFECYCLE.md`
3. `docs/FEATURE_ACTIVATION.md`
4. `docs/AUTONOMOUS_ITERATION.md`
5. `docs/INSTRUCTION_SYNCHRONIZATION.md`

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

Project composition is closed-world. Modules and features absent from the
project spec and feature lock are inert. Stable module promotion requires an
independent consumer or neutral conformance harness.

The reference downstream adoption shape is a project-local `morphospace/`
workspace beside an application README. It selects only the application's
baseline shell, lists optional families disabled, leaves unrelated nearby
features absent and inert, and records extraction candidates before source is
moved.

For particle candidates, search Matter's particle and surface-runtime
contracts first. Keep relation inputs in Lattice, appearance/projection in
Optics, platform/render adapters in Quest, and composition/private policy in
the app. A new app-derived particle schema requires evidence that these
existing owner contracts cannot express the neutral boundary.
The accepted conformance surfaces are Matter
`fixtures/particles/contract-conformance.json`, Lattice
`rusty.lattice.situated_anchor.v1`, and Optics
`fixtures/particles/matter-visual-conformance.json`. Their damaged fixtures
reject app, platform, renderer-resource, private-driver, and high-rate-control
leakage.
Quest adoption routes through `crates/rusty-quest-particle-adapter`: Spatial
Camera Panel selects it only from explicit surface-layer start, while native
renderer selects it only through its conformance profile. Both default
disabled and share no application policy.

The hand substrate routes tracked capability, joint relations, reference
space, coordinate basis, confidence, and staleness through Lattice; bind rigs
and deterministic CPU skinning through Matter; and provider/rig/hand-preserving
visual profiles through Optics. Platform adapters stay outside all three cores.

Quest adoption routes through `crates/rusty-quest-hand-adapter`. The native
OpenXR hand lab enables it only through its explicit app build, while Spatial
selects it only when the live-hand bridge starts. The consumers share
conversion and parity contracts, not provider acquisition, renderer resources,
or application policy.

For peer-workflow consolidation, `quest-termux-lab` owns only the sanitized
`source`/`privacy` profile. `rusty-quest-sidecar-mesh` owns the six-phase
source/privacy/approval/submission/decision/receipt planning DAG. The DAG
indexes retained v1 artifacts; it is not an execution engine. Manifold remains
decision, receipt, audit, and accepted-state authority.

The landed Manifold peer authority lives in `rusty-manifold-peer`: adapters
propose stable identity and bounded low-rate status, while Manifold alone
reviews trust/revision/replay/freshness, advances accepted peer state, and
emits decisions, rejections, audit events, and application receipts.

The source-only `rusty-manifold-runtime-host` owns durable authority snapshots,
registered-command review/application, accepted leases, explicit expiry,
replay guards, restart, and audit. Standalone or embedded brokers add policy
and adapters later; they must not fork the host's accepted state.

Broker product selection now resolves in Manifold through an immutable exact
lock. The base product is camera/P2P/BLE-free; camera media, direct Wi-Fi P2P,
and BLE rendezvous remain independent opt-ins, and every product selects exactly
one standalone or embedded mode. Rusty Quest may only project the accepted
permission enum into an Android manifest. It must reject stale, expanded, or
union locks rather than inventing packaging authority.

Standalone and embedded broker adoption now routes through
`rusty-manifold-broker-adapter`; mode changes placement and adapter role only,
not review/application behavior. Quest product paths use
`rusty-quest-broker-authority` and thin JNI classes that preserve the Manifold
receipt, next snapshot, and `module.runtime.host` decision owner. Java must not
carry command, lease, revision, replay, or rejection policy.

Cross-app broker admission uses Quest signature-scoped Binder caller evidence
over `rusty-manifold-admission`. Android owns UID/package/signing-certificate
projection and SecureRandom entropy; Manifold owns explicit grants, short-lived
opaque tokens, capability-use replay, expiry, revocation, revisions, and audit.
Do not treat a WebSocket acknowledgement, Java allowlist, or shared secret as
product authorization.

Real product apps consume admission through a policy-free shared client SDK.
Each keeps a distinct package/client identity, exact feature lock, marker
namespace, grant, and app-local capability while converging only on accepted
Manifold peer/media contracts. Keep capabilities canonical and sorted, keep
app properties/defaults out of the SDK, and preserve live authority revision
across service rebinds. Multi-app device proof requires distinct app ids, both
token lifecycles, bleed checks, generic media evidence folding, zero fatals,
and complete package cleanup.

Reusable product Wi-Fi Direct must not depend on a connectivity-lab harness.
Keep temporary group topology, platform `Network` observation, Rust-owned
socket bind/exchange, and cleanup as separate receipts. If a Quest exposes a
valid `p2p0` route without a public Android `Network`, record that absence
honestly and require the Rust socket provider to prove its own explicit bind,
bounded non-media exchange, close, and inactive cleanup.

Authenticated BLE rendezvous is evidence, not peer-session or topology
authority. Project it through a Quest peer-session adapter; Manifold owns
accept/reject, revision, replay, peer change, expiry, and revocation. Product
topology requires a fresh current-revision Manifold authorization bound to the
exact topology contract and local role. Prove rejected, stale, and revoked
receipts leave topology non-grouped before the accepted product exchange.

Bounded N-peer membership belongs to Manifold. It owns the accepted set,
revision, deterministic coordinator, direct-route ranking, split-brain
rejection, expiry, revocation, direct-lane eligibility, and audit. Public-lab
and sidecar artifacts remain source/privacy/advisory only; a platform adapter
may add independently authenticated live-pair evidence. Advisory gossip never
authenticates a direct route or carries media.

Generic media sessions use Manifold for accepted low-rate session/stream
references and Quest for receiver-first platform adoption. Keep source,
processor, route provider, sink, codec, and socket authorities explicit.
Camera2 and display-composite conform independently; remote-camera remains a
compatibility adapter rather than a source of generic defaults.

When repo routing, module placement, activation, validation, or public/private
rules change, synchronize this router and the nearest repo instructions in the
same iteration unit. Keep detailed recipes in linked docs.
