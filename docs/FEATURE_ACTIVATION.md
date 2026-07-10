# Feature Activation

Rusty Morphospace projects use a closed-world activation model. A module may
exist in source, be built, or be registered by an app shell without affecting
the current application.

## Default Rule

Absent means inert.

- An unlisted module is unavailable to the project.
- A listed module without a feature-lock entry is inactive.
- A feature-lock entry with `enabled: false` is inactive.
- Only an explicit enabled entry may alter packaging or runtime behavior.

Inactive features must not change permissions, manifest entries, package
contents, services, scene graphs, input routes, marker streams, network
listeners, media paths, assets, private payload behavior, or runtime defaults.

## Activation Record

Every enabled feature declares:

- feature and module IDs;
- who or what requested activation;
- the feature descriptor or app spec;
- dependencies and conflicts;
- permissions, routes, and assets introduced;
- each affected parameter and its single authority owner;
- the required effective-runtime receipt and acceptance marker.

The project spec states which modules are available. The feature lock states
which of those modules are active. Neither file changes the module's internal
authority model.

## Activation Flow

1. Add the module to the project spec with lane, contract, maturity, and
   dependencies.
2. Add a feature-lock entry. Keep it disabled while wiring adapters.
3. Declare packaging, permissions, routes, assets, parameters, dependencies,
   and conflicts.
4. Enable it explicitly for the project or run profile.
5. Validate the adapter write or configuration load.
6. Validate an effective marker from the consuming runtime.
7. Record the receipt without placing raw private evidence in a public repo.

Adapter readback alone is not activation acceptance.

## Parameter Authority

A parameter appears once in the project authority map. Feature entries refer
to that owner; they do not create a second owner. If two entrypoints can set a
value, both adapt into the named owner and the consuming runtime reports the
effective value.

## Dependency And Conflict Rules

- Enabled feature dependencies must be declared project modules.
- A feature cannot silently enable another feature.
- Conflicting enabled features fail validation.
- An application-specific default cannot be injected into a generic module.
- Feature removal must return packaging and runtime behavior to the declared
  inactive baseline.

## Validation Questions

- Does disabling the feature remove every introduced permission, route, asset,
  listener, stream, and scene contribution?
- Are effective markers emitted by the consumer rather than the adapter?
- Are unrelated features byte-for-byte or behaviorally unchanged?
- Can another project choose a different activation without forking the
  reusable module?
