# Hello Morphospace V2

This is the smallest checked-in protocol-v2 onboarding workspace. It begins
with an empty feature/effect closure and one proposed documentation-only unit;
nothing is active and no device is required.

Validate it from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkflowContracts.ps1 `
  -WorkspaceRoot .\examples\hello-morphospace-v2\morphospace
```

## Walkthrough

1. The [project specification](morphospace/project.spec.json) declares one
   application shell and closed-world activation.
2. The [feature lock](morphospace/feature.lock.json) has no selected features
   and an empty effect union. Adding source code alone cannot activate it.
3. A real feature starts with an owner-issued descriptor and is resolved with
   `scripts/Resolve-FeatureLock.ps1`; never hand-invent descriptor hashes or a
   lock fingerprint.
4. [hello-001](morphospace/iteration-units/hello-001.json) is proposed and
   path-bounded. Review it into `ready`, then claim it through
   `scripts/Invoke-WorkUnitAutomation.ps1`; do not hand-edit state transitions.
5. Run the unit's declared validation. `RecordValidation` binds a typed receipt;
   `Accept` revalidates current scope and evidence. A passing command by itself
   is not acceptance.
6. Add one compact JSONL event for every owned transition and keep private/local
   evidence outside this public example.

For the complete contract, read
[Project Workspace Protocol](../../docs/PROJECT_WORKSPACE_PROTOCOL.md) and
[Autonomous Iteration](../../docs/AUTONOMOUS_ITERATION.md).
