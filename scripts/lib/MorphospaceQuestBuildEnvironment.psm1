Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:ResolvedQuestContexts=[Runtime.CompilerServices.ConditionalWeakTable[object,object]]::new()
function Stop-QuestBuildContext([string]$Code){$e=[InvalidOperationException]::new("Quest build context refused: $Code.");$e.Data['ReasonCode']=$Code;throw $e}
function Get-QuestContextBytesHash([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function Get-QuestContextValueHash([object]$Value){Get-QuestContextBytesHash ([Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 32 -Compress)))}
function Get-QuestContextEnvironmentHash([Collections.IDictionary]$Values){$rows=@($Values.Keys|Sort-Object -CaseSensitive|ForEach-Object{[ordered]@{name=[string]$_;value=[string]$Values[$_]}});Get-QuestContextValueHash $rows}
function Assert-QuestContextJsonKeys([Text.Json.JsonElement]$Element){
 if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($p in $Element.EnumerateObject()){if(-not$seen.Add($p.Name)){Stop-QuestBuildContext 'context-input-invalid'};Assert-QuestContextJsonKeys $p.Value}}
 elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){foreach($p in $Element.EnumerateArray()){Assert-QuestContextJsonKeys $p}}
}
function Get-QuestContextCanonicalPath([string]$Path,[int]$Depth=0){
 if($Depth-gt32-or-not[IO.Path]::IsPathFullyQualified($Path)){Stop-QuestBuildContext 'context-input-invalid'}
 $full=[IO.Path]::GetFullPath($Path);$current=[IO.Path]::GetPathRoot($full)
 $parts=$full.Substring($current.Length).Split([char[]]@([char]'\',[char]'/'),[StringSplitOptions]::RemoveEmptyEntries)
 foreach($part in $parts){
  $candidate=[IO.Path]::Combine($current,$part)
  try{$item=Get-Item -LiteralPath $candidate -Force -ErrorAction Stop}catch{Stop-QuestBuildContext 'tool-missing'}
  if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){
   try{$target=$item.ResolveLinkTarget($true)}catch{Stop-QuestBuildContext 'context-input-invalid'}
   if($null-eq$target){Stop-QuestBuildContext 'context-input-invalid'}
   $current=Get-QuestContextCanonicalPath $target.FullName ($Depth+1)
  }else{$current=$candidate}
 }
 return [IO.Path]::GetFullPath($current)
}
function Assert-QuestContextCanonicalPath([string]$Path,[string]$Code){
 $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
 if(-not$comparer.Equals([IO.Path]::GetFullPath($Path),(Get-QuestContextCanonicalPath $Path))){Stop-QuestBuildContext $Code}
}
function Open-QuestContextReadHold([string]$Path,[string]$Sha256,[string]$Code){
 if(-not[IO.Path]::IsPathFullyQualified($Path)-or$Sha256-cnotmatch'^[a-f0-9]{64}$'){Stop-QuestBuildContext $Code}
 Assert-QuestContextCanonicalPath $Path $Code
 try{$s=[IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}catch{Stop-QuestBuildContext $Code}
 try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)).ToLowerInvariant();$s.Position=0;if($hash-cne$Sha256){Stop-QuestBuildContext $Code};return $s}catch{$s.Dispose();throw}
}
function Invoke-QuestContextEnvironmentValues([Collections.IDictionary]$Values,[scriptblock]$Action,[object[]]$Arguments=@()){
 # A named per-process mutex covers separate module/runspace instances too.
 $gate=[Threading.Mutex]::new($false,"morphospace-quest-build-environment-$PID")
 $held=$false;$before=$null;$slot=[Threading.Thread]::GetNamedDataSlot("morphospace-quest-build-environment-values");$previousScope=[Threading.Thread]::GetData($slot);$scopeEntered=$false
 try{
  try{$held=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
  if(-not$held){Stop-QuestBuildContext 'environment-busy'}
  $scopeHash=Get-QuestContextEnvironmentHash $Values
  if($null-ne$previousScope-and[string]$previousScope-cne$scopeHash){Stop-QuestBuildContext 'environment-busy'}
  [Threading.Thread]::SetData($slot,$scopeHash);$scopeEntered=$true
  $before=[Environment]::GetEnvironmentVariables()
  foreach($name in @([Environment]::GetEnvironmentVariables().Keys)){[Environment]::SetEnvironmentVariable([string]$name,[System.Management.Automation.Language.NullString]::Value,'Process')}
  foreach($name in $Values.Keys){[Environment]::SetEnvironmentVariable([string]$name,[string]$Values[$name],'Process')}
  & $Action @Arguments
 }finally{
  if($null-ne$before){foreach($name in @([Environment]::GetEnvironmentVariables().Keys)){[Environment]::SetEnvironmentVariable([string]$name,[System.Management.Automation.Language.NullString]::Value,'Process')};foreach($name in $before.Keys){[Environment]::SetEnvironmentVariable([string]$name,[string]$before[$name],'Process')}}
  if($scopeEntered){[Threading.Thread]::SetData($slot,$previousScope)}
  if($held){$gate.ReleaseMutex()};$gate.Dispose()
 }
}
function Invoke-QuestContextToolProbe([string]$Path,[string[]]$Arguments,[Collections.IDictionary]$Environment,[string]$WorkingDirectory){
 $result=Invoke-QuestContextEnvironmentValues $Environment {
  param($executable,$argv,$directory)
  Push-Location -LiteralPath $directory
  try{
   $PSNativeCommandUseErrorActionPreference=$false
   try{$output=@(& $executable @argv 2>&1);$code=$LASTEXITCODE}catch{Stop-QuestBuildContext 'tool-probe-failed'}
   if($code-ne0){Stop-QuestBuildContext 'tool-probe-failed'}
   [pscustomobject]@{Text=($output|ForEach-Object{[string]$_})-join"`n"}
  }finally{Pop-Location}
 } @($Path,$Arguments,$WorkingDirectory)
 return [string]$result.Text
}
function Get-QuestResolvedFingerprint([object]$Context){
 $tools=@($Context.Tools.Keys|Sort-Object|ForEach-Object{[ordered]@{id=[string]$_;path=[string]$Context.Tools[$_].Path;sha256=[string]$Context.Tools[$_].Sha256}})
 Get-QuestContextValueHash ([ordered]@{path=$Context.ContextPath;sha256=$Context.ContextSha256;environment_sha256=(Get-QuestContextEnvironmentHash $Context.EnvironmentValues);tools=$tools;channel=$Context.ToolchainChannel;directory=$Context.WorkingDirectory;evidence=$Context.Evidence})
}
function Assert-QuestContextBareGit([object]$Context){
 if(-not$Context.Tools.ContainsKey('git')){return}
 $matches=@(Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)
 if(-not$matches.Count){Stop-QuestBuildContext 'tool-missing'}
 $actual=Get-QuestContextCanonicalPath ([string]$matches[0].Source)
 $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
 if(-not$comparer.Equals($actual,$Context.Tools.git.Path)){Stop-QuestBuildContext 'context-binding-conflict'}
}
function Resolve-MorphospaceQuestBuildContext {
 [CmdletBinding()]
 param(
  [Parameter(Mandatory)][string]$ContextPath,[Parameter(Mandatory)][string]$ContextSha256,
  [ValidateSet('cargo','rustc','rustup','pwsh','git')][string[]]$RequiredTools=@(),
  [string[]]$RequiredTargets=@(),[Parameter(Mandatory)][string]$WorkingDirectory,
  [string]$ToolchainChannel='', [string[]]$PassthroughVariables=@(),
  [hashtable]$EnvironmentBindings=@{}
 )
 $holds=[Collections.Generic.List[IO.FileStream]]::new()
 try{
  foreach($source in $script:QuestContextOwnerSources){$holds.Add((Open-QuestContextReadHold $source.Path $source.Sha256 'context-owner-source-changed'))}
  $full=Get-QuestContextCanonicalPath $ContextPath
  $stream=Open-QuestContextReadHold $full $ContextSha256 'context-hash-mismatch';$holds.Add($stream)
  if($stream.Length-gt1048576){Stop-QuestBuildContext 'context-input-invalid'}
  $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$false,4096,$true)
  try{$raw=$reader.ReadToEnd()}finally{$reader.Dispose()}
  $json=$null;try{$json=[Text.Json.JsonDocument]::Parse($raw);Assert-QuestContextJsonKeys $json.RootElement}finally{if($null-ne$json){$json.Dispose()}}
  if(-not(Test-Json -Json $raw -SchemaFile (Join-Path $PSScriptRoot '../../schemas/local-quest-build-context-v1.schema.json') -ErrorAction SilentlyContinue)){Stop-QuestBuildContext 'context-input-invalid'}
  $document=ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 32 -DateKind String
  if(-not[IO.Path]::IsPathFullyQualified($WorkingDirectory)-or-not(Test-Path -LiteralPath $WorkingDirectory -PathType Container)){Stop-QuestBuildContext 'environment-invalid'}
  $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
  $values=[Collections.Generic.Dictionary[string,string]]::new($comparer)
  foreach($name in $document.environment.Keys){if($values.ContainsKey($name)-or([string]$document.environment[$name]).Contains([char]0)){Stop-QuestBuildContext 'environment-invalid'};$values.Add($name,[string]$document.environment[$name])}
  $tools=@{}
  foreach($id in $document.tools.Keys){
   $tool=$document.tools[$id];$path=Get-QuestContextCanonicalPath ([string]$tool.path)
   $hold=Open-QuestContextReadHold $path ([string]$tool.sha256) 'tool-hash-mismatch';$holds.Add($hold)
   $application=@(Get-Command -Name ([IO.Path]::GetFullPath($path)) -CommandType Application -ErrorAction SilentlyContinue)
   if($application.Count-ne1){Stop-QuestBuildContext 'tool-missing'}
   $tools[$id]=[pscustomobject]@{Path=[IO.Path]::GetFullPath($path);Sha256=[string]$tool.sha256}
  }
  foreach($id in $RequiredTools){if(-not$tools.ContainsKey($id)){Stop-QuestBuildContext 'tool-missing'}}
  $channel=if($document.Contains('rust_toolchain')){[string]$document.rust_toolchain.channel}else{''}
  if($ToolchainChannel-and$ToolchainChannel-cne$channel){Stop-QuestBuildContext 'toolchain-compiler-mismatch'}
  if($tools.ContainsKey('rustc')){
   if($values.ContainsKey('RUSTC')-and$values['RUSTC']-cne$tools.rustc.Path){Stop-QuestBuildContext 'context-binding-conflict'}
   $values['RUSTC']=$tools.rustc.Path
  }
  if($channel){if($values.ContainsKey('RUSTUP_TOOLCHAIN')-and$values['RUSTUP_TOOLCHAIN']-cne$channel){Stop-QuestBuildContext 'context-binding-conflict'};$values['RUSTUP_TOOLCHAIN']=$channel}
  foreach($name in $PassthroughVariables){if($name-cnotmatch'^[A-Z][A-Z0-9_]{0,95}$'){Stop-QuestBuildContext 'environment-invalid'};if(-not$values.ContainsKey($name)){$v=[Environment]::GetEnvironmentVariable($name);if($null-ne$v){$values[$name]=$v}}}
  foreach($name in $EnvironmentBindings.Keys){if($name-cnotmatch'^[A-Z][A-Z0-9_]{0,95}$'){Stop-QuestBuildContext 'environment-invalid'};if($values.ContainsKey($name)-and$values[$name]-cne[string]$EnvironmentBindings[$name]){Stop-QuestBuildContext 'context-binding-conflict'};$values[$name]=[string]$EnvironmentBindings[$name]}
  if($IsWindows){
   foreach($name in @('SYSTEMROOT','SYSTEMDRIVE','WINDIR','COMSPEC','PATH','PATHEXT','TEMP','TMP','USERPROFILE')){if(-not$values.ContainsKey($name)-or-not$values[$name]){Stop-QuestBuildContext 'environment-invalid'}}
   if($values['SYSTEMDRIVE']-cnotmatch'^[A-Za-z]:$'-or[IO.Path]::GetPathRoot($values['SYSTEMROOT']).TrimEnd('\')-ine$values['SYSTEMDRIVE']){Stop-QuestBuildContext 'environment-invalid'}
   foreach($name in @('SYSTEMROOT','WINDIR','TEMP','TMP','USERPROFILE')){if(-not[IO.Path]::IsPathFullyQualified($values[$name])-or-not(Test-Path -LiteralPath $values[$name] -PathType Container)){Stop-QuestBuildContext 'environment-invalid'}}
   if(-not[IO.Path]::IsPathFullyQualified($values['COMSPEC'])-or-not(Test-Path -LiteralPath $values['COMSPEC'] -PathType Leaf)){Stop-QuestBuildContext 'environment-invalid'}
  }
  if($values.ContainsKey('PATH')){foreach($entry in $values['PATH'].Split([IO.Path]::PathSeparator)){if(-not$entry-or-not[IO.Path]::IsPathFullyQualified($entry)-or-not(Test-Path -LiteralPath $entry -PathType Container)){Stop-QuestBuildContext 'environment-invalid'}}}
  $effective=@{};foreach($name in $values.Keys){$effective[$name]=$values[$name]}
  Invoke-QuestContextEnvironmentValues $effective {param($selected)Assert-QuestContextBareGit $selected} @([pscustomobject]@{Tools=$tools})
  $evidence=[Collections.Generic.List[object]]::new()
  foreach($source in $script:QuestContextOwnerSources){$evidence.Add([ordered]@{kind='context-owner-source';role=$source.Role;sha256=$source.Sha256})}
  foreach($id in @($RequiredTools|Sort-Object -Unique)){
   $arguments=switch($id){'pwsh'{@('-NoProfile','-NonInteractive','-Command','$PSVersionTable.PSVersion.ToString()')};'rustc'{@('-vV')};default{@('--version')}}
   $observed=Invoke-QuestContextToolProbe $tools[$id].Path $arguments $effective $WorkingDirectory
   $evidence.Add([ordered]@{kind='selected-tool';tool_id=$id;sha256=$tools[$id].Sha256;output_sha256=(Get-QuestContextValueHash $observed)})
  }
  if($RequiredTargets.Count){
   if(-not$channel-or-not$tools.ContainsKey('rustup')-or-not$tools.ContainsKey('rustc')){Stop-QuestBuildContext 'tool-missing'}
   foreach($target in $RequiredTargets){if($target-cnotmatch'^[A-Za-z0-9_.-]{1,128}$'){Stop-QuestBuildContext 'context-input-invalid'}}
   $selectedVersion=(Invoke-QuestContextToolProbe $tools.rustc.Path @('-vV') $effective $WorkingDirectory).Replace("`r`n","`n").Trim()
   $toolchainVersion=(Invoke-QuestContextToolProbe $tools.rustup.Path @('run',$channel,'rustc','-vV') $effective $WorkingDirectory).Replace("`r`n","`n").Trim()
   $selectedRoot=(Invoke-QuestContextToolProbe $tools.rustc.Path @('--print','sysroot') $effective $WorkingDirectory).Trim()
   $toolchainRoot=(Invoke-QuestContextToolProbe $tools.rustup.Path @('run',$channel,'rustc','--print','sysroot') $effective $WorkingDirectory).Trim()
   if($selectedVersion-cne$toolchainVersion-or-not$comparer.Equals([IO.Path]::GetFullPath($selectedRoot),[IO.Path]::GetFullPath($toolchainRoot))){Stop-QuestBuildContext 'toolchain-compiler-mismatch'}
   $installed=(Invoke-QuestContextToolProbe $tools.rustup.Path @('target','list','--installed','--toolchain',$channel) $effective $WorkingDirectory)-split'\r?\n'
   foreach($target in $RequiredTargets){if($target-cnotin$installed){Stop-QuestBuildContext 'target-missing'};$evidence.Add([ordered]@{kind='required-target';target=$target;installed=$true;channel=$channel;compiler_sha256=$tools.rustc.Sha256})}
  }
  foreach($name in @($effective.Keys|Sort-Object)){$evidence.Add([ordered]@{kind='environment';variable=$name;present=$true;value_sha256=(Get-QuestContextBytesHash ([Text.UTF8Encoding]::new($false).GetBytes([string]$effective[$name])))})}
  $context=[pscustomobject]@{ContextPath=$full;ContextSha256=$ContextSha256;EnvironmentValues=$effective;EnvironmentSha256=(Get-QuestContextEnvironmentHash $effective);Tools=$tools;ToolchainChannel=$channel;WorkingDirectory=[IO.Path]::GetFullPath($WorkingDirectory);Evidence=@($evidence.ToArray())}
  $script:ResolvedQuestContexts.Add($context,[pscustomobject]@{Fingerprint=(Get-QuestResolvedFingerprint $context)})
  return $context
 }catch{
  if($_.Exception.Data.Contains('ReasonCode')){throw}
  Stop-QuestBuildContext 'context-input-invalid'
 }finally{foreach($s in $holds){$s.Dispose()}}
}
function Invoke-MorphospaceQuestBuildEnvironment {
 [CmdletBinding()]
 param([Parameter(Mandatory)][object]$Context,[Parameter(Mandatory)][scriptblock]$Action,[object[]]$ArgumentList=@())
 $binding=$null
 if(-not$script:ResolvedQuestContexts.TryGetValue($Context,[ref]$binding)){Stop-QuestBuildContext 'resolved-context-mutated'}
 if((Get-QuestResolvedFingerprint $Context)-cne$binding.Fingerprint-or(Get-QuestContextEnvironmentHash $Context.EnvironmentValues)-cne$Context.EnvironmentSha256){Stop-QuestBuildContext 'resolved-context-mutated'}
 $holds=[Collections.Generic.List[IO.FileStream]]::new()
 $boundPaths=[Collections.Generic.List[object]]::new()
 try{
  foreach($source in $script:QuestContextOwnerSources){$boundPaths.Add([pscustomobject]@{Path=$source.Path;Sha256=$source.Sha256;Code='context-owner-source-changed'})}
  $boundPaths.Add([pscustomobject]@{Path=$Context.ContextPath;Sha256=$Context.ContextSha256;Code='context-hash-mismatch'})
  foreach($id in $Context.Tools.Keys){$boundPaths.Add([pscustomobject]@{Path=$Context.Tools[$id].Path;Sha256=$Context.Tools[$id].Sha256;Code='tool-hash-mismatch'})}
  foreach($row in $boundPaths){$holds.Add((Open-QuestContextReadHold $row.Path $row.Sha256 $row.Code))}
  foreach($row in $boundPaths){Assert-QuestContextCanonicalPath $row.Path $row.Code}
  Invoke-QuestContextEnvironmentValues $Context.EnvironmentValues {
   param($bound,[scriptblock]$callback,$arguments)
   Assert-QuestContextBareGit $bound
   & $callback @arguments
  } @($Context,$Action,$ArgumentList)
 }finally{
  try{
   foreach($row in $boundPaths){$check=Open-QuestContextReadHold $row.Path $row.Sha256 $row.Code;$check.Dispose()}
   if((Get-QuestResolvedFingerprint $Context)-cne$binding.Fingerprint){Stop-QuestBuildContext 'resolved-context-mutated'}
  }finally{foreach($s in $holds){$s.Dispose()}}
 }
}
function New-MorphospaceQuestBuildContext {
 [CmdletBinding()]
 param(
  [Parameter(Mandatory)][string]$OutputPath,[Parameter(Mandatory)][string]$SourceRoot,
  [Parameter(Mandatory)][string[]]$EnvironmentVariableNames,
  [Parameter(Mandatory)][hashtable]$ToolPaths,[string]$RustToolchainChannel='',
  [string[]]$RequiredTargets=@(),[hashtable]$EnvironmentOverrides=@{}
 )
 # Author data from an already selected developer shell. No SDK/tool installation,
 # developer-shell discovery, signing data or generated runtime wrapper lives here.
 if(-not[IO.Path]::IsPathFullyQualified($OutputPath)-or(Test-Path -LiteralPath $OutputPath)-or-not(Test-Path -LiteralPath (Split-Path $OutputPath -Parent) -PathType Container)){Stop-QuestBuildContext 'context-input-invalid'}
 if(-not$ToolPaths.ContainsKey('git')){Stop-QuestBuildContext 'tool-missing'}
 $tools=[ordered]@{}
 foreach($id in @($ToolPaths.Keys|Sort-Object)){
  if($id-cnotin@('cargo','rustc','rustup','pwsh','git')-or-not[IO.Path]::IsPathFullyQualified([string]$ToolPaths[$id])-or-not(Test-Path -LiteralPath $ToolPaths[$id] -PathType Leaf)){Stop-QuestBuildContext 'tool-missing'}
  $tools[$id]=[ordered]@{path=(Get-QuestContextCanonicalPath ([string]$ToolPaths[$id]));sha256=(Get-FileHash -LiteralPath $ToolPaths[$id] -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
 $selectedGitExecutable=[string]$tools.git.path
 $gitHold=Open-QuestContextReadHold $tools.git.path $tools.git.sha256 'tool-hash-mismatch'
 try{
  $PSNativeCommandUseErrorActionPreference=$false
  try{$null=& $selectedGitExecutable -C $SourceRoot check-ignore --no-index -- $OutputPath 2>$null;$gitCode=$LASTEXITCODE}catch{Stop-QuestBuildContext 'context-output-not-ignored'}
  if($gitCode-ne0){Stop-QuestBuildContext 'context-output-not-ignored'}
 }finally{$gitHold.Dispose()}
 $environment=[ordered]@{}
 foreach($name in $EnvironmentVariableNames){
  if($name-cnotmatch'^[A-Z][A-Z0-9_]{0,95}$'-or$name-match'PASSWORD|TOKEN|SECRET|KEY'-or$environment.Contains($name)){Stop-QuestBuildContext 'environment-invalid'}
  $value=[Environment]::GetEnvironmentVariable($name);if($null-ne$value){$environment[$name]=$value}
 }
 foreach($name in $EnvironmentOverrides.Keys){if($name-cnotmatch'^[A-Z][A-Z0-9_]{0,95}$'-or$name-match'PASSWORD|TOKEN|SECRET|KEY'){Stop-QuestBuildContext 'environment-invalid'};$environment[$name]=[string]$EnvironmentOverrides[$name]}
 $document=[ordered]@{schema='rusty.morphospace.local_quest_build_context.v1';environment=$environment;tools=$tools}
 if($RustToolchainChannel){$document.rust_toolchain=[ordered]@{channel=$RustToolchainChannel}}
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($document|ConvertTo-Json -Depth 12)+"`n")
 $stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 $sha=Get-QuestContextBytesHash $bytes
 # A refused authored input remains retained as data; no overwrite/delete/retry.
 $resolved=Resolve-MorphospaceQuestBuildContext -ContextPath $OutputPath -ContextSha256 $sha -RequiredTools @($ToolPaths.Keys) -RequiredTargets $RequiredTargets -WorkingDirectory $SourceRoot
 [pscustomobject]@{path=[IO.Path]::GetFullPath($OutputPath);sha256=$sha;environment_sha256=$resolved.EnvironmentSha256;tool_ids=@($tools.Keys);execution_authority=$false}
}
$script:QuestContextOwnerSources=@(
 [pscustomobject]@{Role='module';Path=(Get-QuestContextCanonicalPath $PSCommandPath);Sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()},
 [pscustomobject]@{Role='schema';Path=(Get-QuestContextCanonicalPath (Join-Path $PSScriptRoot '../../schemas/local-quest-build-context-v1.schema.json'));Sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot '../../schemas/local-quest-build-context-v1.schema.json') -Algorithm SHA256).Hash.ToLowerInvariant()}
)
Export-ModuleMember -Function Resolve-MorphospaceQuestBuildContext,Invoke-MorphospaceQuestBuildEnvironment,New-MorphospaceQuestBuildContext
