Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MorphospaceProtocolCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'MorphospacePreparationRepositoryScope.psm1')

function Get-MorphospaceDevelopmentEnvelopeHash { param([object]$Value) Get-MorphospaceCanonicalJsonSha256 $Value }
function Copy-MorphospaceDevelopmentEnvelopeValue { param([object]$Value) $Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -DateKind String }
function Get-MorphospaceDevelopmentEnvelopeSchemaPin {
    param([string]$Revision,[string]$SchemaFile)
    "https://raw.githubusercontent.com/MesmerPrism/rusty-morphospace-work-environment/$Revision/schemas/$SchemaFile"
}
function Get-MorphospaceDevelopmentEnvelopePinnedRevision {
    param([string]$Uri,[string]$SchemaFile,[string]$Context)
    $pattern='^https://raw\.githubusercontent\.com/MesmerPrism/rusty-morphospace-work-environment/([0-9a-f]{40})/schemas/'+[regex]::Escape($SchemaFile)+'$'
    if($Uri-cnotmatch$pattern){throw "Preparation $Context schema pin is not an exact Work Environment revision."}
    $Matches[1]
}
function Get-MorphospaceDevelopmentEnvelopeModuleRegistry {
    param([object]$Project,[object]$FeatureLock)
    [pscustomobject][ordered]@{
        lock_revision=[int]$FeatureLock.revision
        lock_fingerprint=[string]$FeatureLock.lock_fingerprint
        modules=@($Project.modules|Where-Object{$_.selected-eq$true}|Sort-Object module_id|ForEach-Object{
            [pscustomobject][ordered]@{
                module_id=[string]$_.module_id
                owner_repo=[string]$_.source_repo
                maturity=[string]$_.maturity
                contract=[string]$_.contract
                contract_revision=[string]$_.contract_revision
            }
        })
    }
}
function Assert-MorphospaceDevelopmentEnvelopeLockAndRegistry {
    param([object]$Project,[object]$FeatureLock,[object]$State,[string]$Context)
    if(-not(Test-MorphospaceFeatureLockFingerprint $FeatureLock)){throw "Preparation $Context feature-lock fingerprint is stale or damaged."}
    $expectedRegistry=Get-MorphospaceDevelopmentEnvelopeModuleRegistry $Project $FeatureLock
    if((Get-MorphospaceDevelopmentEnvelopeHash $State.module_registry)-cne(Get-MorphospaceDevelopmentEnvelopeHash $expectedRegistry)){throw "Preparation $Context workspace module registry does not match the feature lock and selected modules."}
}
function Assert-MorphospaceDevelopmentEnvelopeRepreparationDefect {
    param([object]$Project,[object]$FeatureLock,[object]$State)
    $expectedRegistry=Get-MorphospaceDevelopmentEnvelopeModuleRegistry $Project $FeatureLock
    if((Test-MorphospaceFeatureLockFingerprint $FeatureLock)-and
        (Get-MorphospaceDevelopmentEnvelopeHash $State.module_registry)-ceq(Get-MorphospaceDevelopmentEnvelopeHash $expectedRegistry)){
        throw 'Repreparation is reserved for an exact lock-fingerprint or module-registry defect after retirement.'
    }
}
function Assert-MorphospaceDevelopmentEnvelopeAdditiveProject {
    param([object]$Current,[object]$Target,[bool]$AllowSchemaPinAdvance,[AllowNull()][object[]]$OwnerRepositories=$null)
    if([string]$Current.project_id-cne[string]$Target.project_id-or[int]$Target.revision-ne([int]$Current.revision+1)){throw 'Preparation project identity or single revision advance is invalid.'}
    foreach($property in @('selected_features','denied_features','selected_modules','denied_modules','allowed_permissions','denied_permissions','data_classes')){
        foreach($value in @($Current.composition.$property)){if(@($Target.composition.$property)-cnotcontains$value){throw "Preparation removes current composition value '$property/$value'."}}
    }
    $currentRepos=@{};foreach($repo in @($Current.repositories)){$currentRepos[[string]$repo.repo_id]=$repo};$targetRepos=@{};foreach($repo in @($Target.repositories)){$targetRepos[[string]$repo.repo_id]=$repo}
    if ($null -eq $OwnerRepositories) {
        foreach($id in $currentRepos.Keys){if(-not$targetRepos.ContainsKey($id)-or(Get-MorphospaceDevelopmentEnvelopeHash $currentRepos[$id])-cne(Get-MorphospaceDevelopmentEnvelopeHash $targetRepos[$id])){throw "Preparation removes or rewrites repository '$id'."}}
    } else {
        Assert-MorphospacePreparationRepositoryRoots -CurrentRepositories @($Current.repositories) -TargetRepositories @($Target.repositories) -OwnerRepositories $OwnerRepositories
    }
    $currentProfiles=@{};foreach($profile in @($Current.validation_profiles)){$id=[string]$profile.profile_id;if($currentProfiles.ContainsKey($id)){throw "Preparation current project repeats validation profile '$id'."};$currentProfiles[$id]=$profile}
    $targetProfiles=@{};foreach($profile in @($Target.validation_profiles)){$id=[string]$profile.profile_id;if($targetProfiles.ContainsKey($id)){throw "Preparation target project repeats validation profile '$id'."};$targetProfiles[$id]=$profile}
    foreach($id in $currentProfiles.Keys){if(-not$targetProfiles.ContainsKey($id)-or(Get-MorphospaceDevelopmentEnvelopeHash $currentProfiles[$id])-cne(Get-MorphospaceDevelopmentEnvelopeHash $targetProfiles[$id])){throw "Preparation removes or rewrites validation profile '$id'."}}
    $mutable=@('revision','composition','repositories','validation_profiles');if($AllowSchemaPinAdvance){$mutable+=,'$schema'}
    foreach($property in @($Current.psobject.Properties.Name)){if($property -notin $mutable -and (Get-MorphospaceDevelopmentEnvelopeHash $Current.$property)-cne(Get-MorphospaceDevelopmentEnvelopeHash $Target.$property)){throw "Preparation rewrites non-envelope project property '$property'."}}
}
function Assert-MorphospaceDevelopmentEnvelopeOwnerRoots {
    param([object[]]$Rows,[object]$Project,[hashtable]$Map)
    $projectById=@{};foreach($repo in @($Project.repositories)){$projectById[[string]$repo.repo_id]=$repo}
    $seen=@{};foreach($row in @($Rows)){
        $id=[string]$row.repo_id;if(-not$projectById.ContainsKey($id)-or-not$Map.ContainsKey($id)){throw "Preparation repository '$id' is absent from project or repository map."}
        $roots=@($row.source_roots|ForEach-Object{([string]$_).Replace('\\','/')});if($roots.Count-ne@($roots|Sort-Object -Unique -CaseSensitive).Count){throw "Preparation repeats a source root for '$id'."}
        foreach($sourceRoot in $roots){$canonical=ConvertTo-MorphospaceProtocolRelativePath $sourceRoot.TrimEnd('/');$canonical=if($sourceRoot.EndsWith('/')){"$canonical/"}else{$canonical};if($canonical-cne$sourceRoot){throw "Preparation source root '$id/$sourceRoot' is not canonical."};foreach($other in @($seen[$id]|Where-Object{$null-ne$_})){if($canonical-eq$other-or$canonical.StartsWith($other.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)-or$other.StartsWith($canonical.TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)){throw "Preparation source roots overlap for '$id'."}};$seen[$id]=@($seen[$id]|Where-Object{$null-ne$_})+$canonical
            $allowed=@($projectById[$id].allowed_paths|Where-Object{$canonical-eq$_-or$canonical.StartsWith(([string]$_).TrimEnd('/')+'/',[StringComparison]::OrdinalIgnoreCase)});if($allowed.Count-eq0){throw "Preparation root '$id/$canonical' exceeds project authority."}
        }
    }
}
function Assert-MorphospaceDevelopmentEnvelopeRepositoryRoots {
    param([object[]]$CurrentRepositories,[object[]]$TargetRepositories,[object[]]$OwnerRepositories)
    Assert-MorphospacePreparationRepositoryRoots -CurrentRepositories $CurrentRepositories -TargetRepositories $TargetRepositories -OwnerRepositories $OwnerRepositories
}
function Get-MorphospaceDevelopmentEnvelopeTargetState {
    param([object]$Preparation,[object]$Project,[object]$FeatureLock,[object]$State)
    $targetState=Copy-MorphospaceDevelopmentEnvelopeValue $State
    $pinProperty=$Preparation.envelope.psobject.Properties['schema_pin_revision']
    if($null-eq$pinProperty){
        if((Get-MorphospaceDevelopmentEnvelopeHash $Project.'$schema')-cne(Get-MorphospaceDevelopmentEnvelopeHash $Preparation.envelope.project.'$schema')-or(Get-MorphospaceDevelopmentEnvelopeHash $FeatureLock.'$schema')-cne(Get-MorphospaceDevelopmentEnvelopeHash $Preparation.envelope.feature_lock.'$schema')){throw 'Preparation schema pins may change only through schema_pin_revision.'}
    }else{
        $targetRevision=[string]$pinProperty.Value
        $projectRevision=Get-MorphospaceDevelopmentEnvelopePinnedRevision ([string]$Project.'$schema') 'project-spec-v2.schema.json' 'current project'
        $lockRevision=Get-MorphospaceDevelopmentEnvelopePinnedRevision ([string]$FeatureLock.'$schema') 'feature-lock-v2.schema.json' 'current feature-lock'
        $stateRevision=Get-MorphospaceDevelopmentEnvelopePinnedRevision ([string]$State.'$schema') 'workspace-state-v2.schema.json' 'current workspace-state'
        if($projectRevision-cne$lockRevision-or$projectRevision-cne$stateRevision){throw 'Preparation current schema pins do not share one exact Work Environment revision.'}
        if($targetRevision-ceq$projectRevision){throw 'Preparation schema pin target must differ from the current Work Environment revision.'}
        if([string]$Preparation.envelope.project.'$schema'-cne(Get-MorphospaceDevelopmentEnvelopeSchemaPin $targetRevision 'project-spec-v2.schema.json')-or[string]$Preparation.envelope.feature_lock.'$schema'-cne(Get-MorphospaceDevelopmentEnvelopeSchemaPin $targetRevision 'feature-lock-v2.schema.json')){throw 'Preparation target project and feature-lock schema pins do not match schema_pin_revision.'}
        $targetState.'$schema'=Get-MorphospaceDevelopmentEnvelopeSchemaPin $targetRevision 'workspace-state-v2.schema.json'
    }
    if((Get-MorphospaceDevelopmentEnvelopeHash $FeatureLock)-cne(Get-MorphospaceDevelopmentEnvelopeHash $Preparation.envelope.feature_lock)){
        $targetState.module_registry=Get-MorphospaceDevelopmentEnvelopeModuleRegistry $Preparation.envelope.project $Preparation.envelope.feature_lock
    }
    $targetState
}
function Assert-MorphospaceDevelopmentEnvelope {
    param([object]$Preparation,[object]$Project,[object]$FeatureLock)
    $targetProject=$Preparation.envelope.project;$targetLock=$Preparation.envelope.feature_lock
    if([string]$targetProject.project_id-cne[string]$Preparation.project_id-or[string]$targetLock.project_id-cne[string]$Preparation.project_id){throw 'Preparation envelope project identities are not exact.'}
    if([int]$targetLock.project_revision-ne[int]$targetProject.revision){throw 'Preparation feature-lock project revision differs from the target project revision.'}
    if([int]$targetLock.revision-ne([int]$FeatureLock.revision+1)){throw 'Preparation feature lock must advance exactly one revision.'}
    $old=@{};foreach($f in @($FeatureLock.features)){$id=[string]$f.feature_id;if($old.ContainsKey($id)){throw "Preparation current feature lock repeats '$id'."};$old[$id]=$f};$new=@{};foreach($f in @($targetLock.features)){$id=[string]$f.feature_id;if($new.ContainsKey($id)){throw "Preparation target feature lock repeats '$id'."};$new[$id]=$f}
    foreach($id in $old.Keys){if(-not$new.ContainsKey($id)){throw "Preparation removes existing feature '$id'."};if((Get-MorphospaceDevelopmentEnvelopeHash $old[$id])-cne(Get-MorphospaceDevelopmentEnvelopeHash $new[$id])){throw "Preparation rewrites existing feature '$id'."}}
    $added=@($new.Keys|Where-Object{-not$old.ContainsKey($_)}|Sort-Object);foreach($id in $added){$feature=$new[$id];if([string]$feature.run_activation_default-cne'disabled'-or$feature.selected-ne$true){throw "Preparation feature '$id' must be selected and default disabled."};if([string]$feature.activation.rule-cne'selected-lock-and-runtime-input'-or@($feature.activation.runtime_inputs).Count-eq0){throw "Preparation feature '$id' requires selected lock and runtime input."}}
    $oldLockSelected=@($FeatureLock.selected_features|Sort-Object -Unique);$newLockSelected=@($targetLock.selected_features|Sort-Object -Unique);foreach($id in $oldLockSelected){if($newLockSelected-cnotcontains$id){throw "Preparation removes selected feature '$id'."}}
    $oldProjectSelected=@($Project.composition.selected_features|Sort-Object -Unique);$newProjectSelected=@($targetProject.composition.selected_features|Sort-Object -Unique);$addedLockSelected=@($newLockSelected|Where-Object{$oldLockSelected-cnotcontains$_}|Sort-Object);$addedProjectSelected=@($newProjectSelected|Where-Object{$oldProjectSelected-cnotcontains$_}|Sort-Object)
    if((Get-MorphospaceDevelopmentEnvelopeHash $added)-cne(Get-MorphospaceDevelopmentEnvelopeHash $addedLockSelected)-or(Get-MorphospaceDevelopmentEnvelopeHash $added)-cne(Get-MorphospaceDevelopmentEnvelopeHash $addedProjectSelected)){throw 'Preparation added feature bindings differ between project composition and feature lock.'}
    foreach($id in @($FeatureLock.denied_features)){if(@($targetLock.denied_features)-cnotcontains$id){throw "Preparation removes denied feature '$id'."}}
    $declaredPermissions=@($Preparation.envelope.allowed_permission_categories|Sort-Object -Unique);if($declaredPermissions-ccontains'none'){if($declaredPermissions.Count-ne1){throw "Preparation permission ceiling 'none' must be the only declared value."};$declaredPermissions=@()}
    $permissionUnion=@($targetLock.effect_union.permissions|Sort-Object -Unique);$projectPermissions=@($targetProject.composition.allowed_permissions|Sort-Object -Unique);if((Get-MorphospaceDevelopmentEnvelopeHash $permissionUnion)-cne(Get-MorphospaceDevelopmentEnvelopeHash $declaredPermissions)-or(Get-MorphospaceDevelopmentEnvelopeHash $projectPermissions)-cne(Get-MorphospaceDevelopmentEnvelopeHash $declaredPermissions)){throw 'Preparation project, feature-lock, and declared permission ceilings differ.'}
    foreach($permission in @($targetProject.composition.denied_permissions)){if($permissionUnion-ccontains$permission){throw "Preparation permits denied permission '$permission'."}}
    if(@($Preparation.envelope.allowed_change_categories).Count-eq0-or@($Preparation.envelope.allowed_effect_categories).Count-eq0){throw 'Preparation requires closed change and effect ceilings.'}
    if([string]$targetLock.lock_fingerprint-cne(Get-MorphospaceFeatureLockFingerprint $targetLock)){throw 'Preparation target feature-lock fingerprint is stale or damaged.'}
    $registeredProfiles=@($targetProject.validation_profiles|ForEach-Object{[string]$_.profile_id})
    $declaredProfiles=@($Preparation.envelope.build_envelope.allowed_profiles|ForEach-Object{[string]$_}|Sort-Object -Unique)
    foreach($profile in $declaredProfiles){if($registeredProfiles-cnotcontains[string]$profile){throw "Preparation build profile '$profile' is not registered in the target project validation profiles."}}
    $currentProfiles=@($Project.validation_profiles|ForEach-Object{[string]$_.profile_id});foreach($profile in @($registeredProfiles|Where-Object{$currentProfiles-cnotcontains$_})){if($declaredProfiles-cnotcontains$profile){throw "Preparation adds validation profile '$profile' outside the declared build profile ceiling."}}
}

Export-ModuleMember -Function Assert-MorphospaceDevelopmentEnvelopeOwnerRoots,Get-MorphospaceDevelopmentEnvelopeModuleRegistry,Assert-MorphospaceDevelopmentEnvelopeLockAndRegistry,Assert-MorphospaceDevelopmentEnvelopeRepreparationDefect,Assert-MorphospaceDevelopmentEnvelopeAdditiveProject,Assert-MorphospaceDevelopmentEnvelopeRepositoryRoots,Get-MorphospaceDevelopmentEnvelopeTargetState,Assert-MorphospaceDevelopmentEnvelope
