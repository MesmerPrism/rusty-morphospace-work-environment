# Feature Activation

Rusty Morphospace projects use a closed-world activation model. A module may
exist in source, be built, or be registered by an app shell without affecting
the current application.

## Default Rule

Absent means inert.

- An unlisted module is unavailable to the project.
- A listed module without a feature-lock entry is inactive.
- A v1 feature-lock entry with `enabled: false` is inactive.
- A v2 feature must be present in `selected_features`, but selection only
  permits packaging. Runtime activation still defaults disabled.
- Runtime effects require both the current lock fingerprint/revision and one
  explicit runtime input allowed by the selected descriptor.

Inactive features must not change permissions, manifest entries, package
contents, services, scene graphs, input routes, marker streams, network
listeners, media paths, assets, private payload behavior, or runtime defaults.

## Activation Record

Every selected v2 feature declares:

- feature and module IDs;
- descriptor version/hash and owner source revision/path/hash;
- dependencies and conflicts;
- exact permissions, services, activities, queries, tools, assets, shaders,
  native libraries, commands, routes, streams, inputs, scenes, and markers;
- each affected parameter and its single authority owner;
- the required effective-runtime receipt and acceptance marker.

The project spec selects and denies modules/features. The resolver computes
the dependency closure, rejects conflicts and permission drift, and
fingerprints the exact effect union. The lock permits composition but does not
by itself activate a run. Neither file changes the module's internal authority
model.

## Activation Flow

1. Add the module to the project spec with lane, contract, maturity, and
   dependencies.
2. Add an owner-issued feature descriptor with exact source revision/hash.
3. Select the feature/module in `project_spec.v2`; declare denied ambient
   features and permissions.
4. Resolve and fingerprint `feature_lock.v2` rather than editing it by hand.
5. Supply a descriptor-approved run profile/property/intent/command input.
6. Validate the adapter write or configuration load.
7. Validate an effective marker binding project ID, feature ID, lock revision,
   and lock fingerprint from the consuming runtime.
8. Record the receipt without placing raw private evidence in a public repo.

Adapter readback alone is not activation acceptance.

## Parameter Authority

A parameter appears once in the project authority map. Feature entries refer
to that owner; they do not create a second owner. If two entrypoints can set a
value, both adapt into the named owner and the consuming runtime reports the
effective value.

## Dependency And Conflict Rules

- Selected feature dependencies must be selected project modules.
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
