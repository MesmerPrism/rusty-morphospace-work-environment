Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Assert-QuestProviderCondition([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw "Quest source provider: $Message"}
}
function Get-QuestProviderPath([string]$Path) {
    Assert-QuestProviderCondition ([IO.Path]::IsPathFullyQualified($Path)) 'An absolute repository root is required.'
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
}
function Get-QuestProviderGitValue([string]$Git,[string]$Root,[string[]]$Arguments) {
    $lines=@(& $Git -C $Root @Arguments 2>$null)
    Assert-QuestProviderCondition ($LASTEXITCODE-eq0-and$lines.Count-eq1) 'Exact Git observation failed.'
    ([string]$lines[0]).Trim()
}
function Get-QuestProviderModulePath([string]$Root) {
    # This is an external, raw-pinned owner module, never a WEF tracked import.
    Join-Path $Root 'tools/lib/SourceComposition.psm1'
}
function Assert-MorphospaceQuestSourceProviderCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Provider)
    foreach($hold in @($Provider.Holds)) {
        $hold.Stream.Position=0
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hold.Stream)).ToLowerInvariant()
        Assert-QuestProviderCondition ($hash-ceq$hold.Sha256-and(Get-FileHash -LiteralPath $hold.Path -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$hold.Sha256) 'Provider document or selected module drifted.'
    }
    # Parse a fresh object each time; no caller DTO or returned Boolean is authority.
    $doc=$Provider.Json|ConvertFrom-Json -Depth 100
    foreach($row in @($doc.repositories)) {
        $root=Get-QuestProviderPath $row.repository
        $observed=Get-QuestProviderPath (Get-QuestProviderGitValue $Provider.Git $root @('rev-parse','--show-toplevel'))
        Assert-QuestProviderCondition ($observed-ceq$root-and(Get-QuestProviderGitValue $Provider.Git $root @('rev-parse','HEAD'))-ceq$row.commit-and(Get-QuestProviderGitValue $Provider.Git $root @('rev-parse','HEAD^{tree}'))-ceq$row.tree) 'Provider repository root or base changed.'
    }
    $assertionArguments=@{Composition=$doc}
    if($Provider.AllowWorkingTreeChanges){$assertionArguments.AllowWorkingTreeChanges=$true}
    # Only the fixed export in the raw-pinned module can attest Quest overlays.
    $assertion=$Provider.Module.ExportedCommands['Assert-QuestBuildSourceCompositionCurrent']
    & $assertion @assertionArguments | Out-Null
    foreach($hold in @($Provider.Holds)) {
        Assert-QuestProviderCondition ((Get-FileHash -LiteralPath $hold.Path -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$hold.Sha256) 'Provider changed during assertion.'
    }
}
function Resolve-MorphospaceQuestSourceProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile,[Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)]$Bindings,[Parameter(Mandatory)][string]$Git)
    $composition=$Profile.preflight.source_composition
    $ref=$composition.provider_document
    Assert-QuestProviderCondition ((@($ref.PSObject.Properties.Name|Sort-Object)-join'|')-ceq'path|provider_binding_id|provider_module_sha256|sha256') 'Provider reference has an unknown or missing field.'
    Assert-QuestProviderCondition ($ref.sha256-cmatch'^[a-f0-9]{64}$'-and$ref.provider_module_sha256-cmatch'^[a-f0-9]{64}$'-and$Bindings.ContainsKey([string]$ref.provider_binding_id)) 'Provider hashes or directory binding are invalid.'
    $binding=$Bindings[[string]$ref.provider_binding_id]
    Assert-QuestProviderCondition ($binding.Kind-ceq'directory'-and@($Profile.environment.PSObject.Properties|Where-Object Value -CEQ $ref.provider_binding_id).Count-gt0) 'Provider must use a selected environment directory binding.'
    $modulePath=Get-QuestProviderModulePath $binding.Path
    $paths=@(@([string]$ref.path,[string]$ref.sha256),@($modulePath,[string]$ref.provider_module_sha256))
    $holds=[Collections.Generic.List[object]]::new()
    try {
        foreach($pair in $paths) {
            Assert-QuestProviderCondition ([IO.Path]::IsPathFullyQualified($pair[0])-and(Test-Path -LiteralPath $pair[0] -PathType Leaf)) 'Provider document/module must be an existing absolute file.'
            $stream=[IO.File]::Open($pair[0],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $holds.Add([pscustomobject]@{Path=[IO.Path]::GetFullPath($pair[0]);Sha256=$pair[1];Stream=$stream})
            Assert-QuestProviderCondition ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()-ceq$pair[1]) 'Provider document/module raw hash differs.'
        }
        $holds[0].Stream.Position=0
        $reader=[IO.StreamReader]::new($holds[0].Stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        try{$json=$reader.ReadToEnd()}finally{$reader.Dispose()}
        $doc=$json|ConvertFrom-Json -Depth 100
        Assert-QuestProviderCondition ((@($doc.PSObject.Properties.Name|Sort-Object)-join'|')-ceq'fingerprint|packages|repositories|schema'-and$doc.schema-cin@('rusty.quest.apk_source_composition.v1','rusty.quest.apk_source_composition.v2')-and$doc.fingerprint-cmatch'^[a-f0-9]{64}$'-and@($doc.repositories).Count-gt0) 'Quest composition shape or identity is invalid.'
        $roots=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($row in @($doc.repositories)) {
            Assert-QuestProviderCondition ((@($row.PSObject.Properties.Name|Sort-Object)-join'|')-ceq'commit|repository|repository_id|role|tracked_worktree_clean|tree|worktree_overlay_sha256'-and$ids.Add([string]$row.repository_id)-and$row.role-cin@('primary','path-dependency','app-owned-input')-and$row.commit-cmatch'^[a-f0-9]{40}$'-and$row.tree-cmatch'^[a-f0-9]{40}$'-and$row.tracked_worktree_clean-is[bool]-and$row.worktree_overlay_sha256-is[string]) 'Provider repository row is invalid or duplicated.'
            $root=Get-QuestProviderPath $row.repository
            Assert-QuestProviderCondition (-not $roots.ContainsKey($root)) 'Provider repository root is ambiguous.'
            Assert-QuestProviderCondition (($row.tracked_worktree_clean-and$row.worktree_overlay_sha256-ceq'')-or(-not$row.tracked_worktree_clean-and$row.worktree_overlay_sha256-cmatch'^[a-f0-9]{64}$')) 'Provider cleanliness/overlay fields differ.'
            $roots.Add($root,$row)
        }
        $primary=@($doc.repositories|Where-Object {$_.repository_id-ceq'rusty-quest'-and$_.role-ceq'primary'})
        Assert-QuestProviderCondition ($primary.Count-eq1-and@( $doc.repositories|Where-Object role -CEQ primary).Count-eq1) 'Quest composition has no unique primary row.'
        $providerRoot=Get-QuestProviderPath $binding.Path
        Assert-QuestProviderCondition ($roots.ContainsKey($providerRoot)-and(Get-QuestProviderPath $roots[$providerRoot].repository)-ceq$providerRoot) 'Selected Quest provider root has no exact composition row.'
        $source=Get-QuestProviderPath $SourceRoot
        Assert-QuestProviderCondition ($roots.ContainsKey($source)-and$roots[$source].role-cin@('primary','app-owned-input')-and$roots[$source].commit-ceq$composition.source.git_revision-and$roots[$source].tree-ceq$composition.source.git_tree) 'SourceRoot does not join the provider/base.'
        foreach($b in $Bindings.Values) {
            if($b.Kind-cne'directory'-or-not$b.Revision){continue}
            $path=Get-QuestProviderPath $b.Path
            # Distinct binding IDs may legitimately alias one unique provider row.
            Assert-QuestProviderCondition ($roots.ContainsKey($path)-and$roots[$path].commit-ceq$b.Revision-and$roots[$path].tree-ceq$b.Tree) 'A bound external repository is missing or has another base.'
        }
        $lane=if($Profile.preflight.PSObject.Properties.Name-ccontains'output'-and$Profile.preflight.output.PSObject.Properties.Name-ccontains'lane'){$Profile.preflight.output.lane}else{'warm'}
        Assert-QuestProviderCondition ($composition.source.require_clean-is[bool]) 'require_clean must be Boolean.'
        $allow=$lane-ceq'warm'-and$composition.source.require_clean-ceq$false
        if(-not$allow){Assert-QuestProviderCondition (@($doc.repositories|Where-Object tracked_worktree_clean -NE $true).Count-eq0) 'Dirty provider sources require explicit local warm opt-in.'}
        $module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
        Assert-QuestProviderCondition ($module.ExportedCommands.ContainsKey('Assert-QuestBuildSourceCompositionCurrent')) 'The fixed Quest assertion export is missing.'
        $state=[pscustomobject]@{Holds=$holds;Json=$json;Git=$Git;Module=$module;AllowWorkingTreeChanges=$allow;Evidence=[ordered]@{path=[IO.Path]::GetFullPath($ref.path);sha256=$ref.sha256;provider_binding_id=$ref.provider_binding_id;provider_module_sha256=$ref.provider_module_sha256;fingerprint=$doc.fingerprint}}
        Assert-MorphospaceQuestSourceProviderCurrent $state
        return $state
    } catch {foreach($hold in $holds){$hold.Stream.Dispose()};throw}
}
function Close-MorphospaceQuestSourceProvider {
    param($Provider)
    if($null-ne$Provider){foreach($hold in $Provider.Holds){$hold.Stream.Dispose()}}
}
Export-ModuleMember -Function Resolve-MorphospaceQuestSourceProvider,Assert-MorphospaceQuestSourceProviderCurrent,Close-MorphospaceQuestSourceProvider
