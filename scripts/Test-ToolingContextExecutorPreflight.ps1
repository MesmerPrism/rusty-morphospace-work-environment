param([switch]$SelfTest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not$SelfTest){throw 'Executor preflight fixture requires -SelfTest.'}
$module=Import-Module (Join-Path $PSScriptRoot 'ToolingContextProvenance.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('tooling-context-preflight-'+[guid]::NewGuid().ToString('N'))
$tool=Join-Path $root 'tool';$workspace=Join-Path $root 'workspace';$routerRoot=Join-Path $root 'router'
function Write-Fixture($Path,$Value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 64),[Text.UTF8Encoding]::new($false))}
function Hash-File($Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Git-Read([string[]]$Arguments){$rows=@(& git -C $tool @Arguments 2>&1);if($LASTEXITCODE-ne0){throw ($rows-join"`n")};$rows}
function Denied([scriptblock]$Body,[string]$Expected,[string]$Name){$message='';try{&$Body|Out-Null}catch{$message=$_.Exception.Message};if($message-cne$Expected){throw "$Name expected '$Expected', actual '$message'"};[Console]::WriteLine("PASS $Name")}
try{
 [IO.Directory]::CreateDirectory($tool)|Out-Null
 Git-Read @('init','--initial-branch=main')|Out-Null
 foreach($pair in @(@('user.name','Tooling Fixture'),@('user.email','fixture@example.invalid'),@('commit.gpgsign','false'),@('core.autocrlf','false'))){Git-Read @('config',$pair[0],$pair[1])|Out-Null}
 Git-Read @('remote','add','origin','https://example.invalid/workflow.git')|Out-Null
 [IO.File]::WriteAllText((Join-Path $tool '.gitattributes'),"*.txt text eol=crlf`n",[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $tool 'entry.txt'),"entry`n",[Text.UTF8Encoding]::new($false))
 Git-Read @('add','--all')|Out-Null;Git-Read @('commit','-m','fixture')|Out-Null
 # Force a genuine clean Git materialization with CRLF; Git status still reports clean.
 Remove-Item -LiteralPath (Join-Path $tool 'entry.txt');Git-Read @('reset','--hard','HEAD')|Out-Null
 if(@(Git-Read @('status','--porcelain=v1')).Count-ne0){throw ('CRLF checkout is not clean: '+((Git-Read @('status','--porcelain=v1'))-join '|'))}
 if(-not[IO.File]::ReadAllText((Join-Path $tool 'entry.txt')).Contains("`r`n")){throw 'Git did not materialize CRLF.'}
 $commit=[string](@(Git-Read @('rev-parse','HEAD'))[0]);$tree=[string](@(Git-Read @('rev-parse','HEAD^{tree}'))[0]);$sha='1'*64
 $closure=@('.gitattributes','entry.txt'|ForEach-Object{[pscustomobject]@{path=$_;sha256=Hash-File (Join-Path $tool $_)}})
 $executor=[pscustomobject]@{repo_id='workflow';remote_url='https://example.invalid/workflow.git';commit=$commit;tree=$tree;entrypoint='entry.txt';closure=$closure;publication_evidence=[pscustomobject]@{path='receipts/publication.json';sha256=$sha}}
 $router=[pscustomobject]@{skill_id='fixture-router';source_repo_id='workflow';commit=$commit;tree=$tree;source_fingerprint=$sha;managed_files=@([pscustomobject]@{path='SKILL.md';sha256=$sha})}
 $compat=[pscustomobject]@{protocol_id='tooling-context-v1';product_lock_schema='rusty.morphospace.workflow.development_envelope_source_composition.v3';repository_map_schema='rusty.morphospace.workflow.repository_map.v1';allowed_actions=@(Get-MorphospaceToolingContextAllowedActions);receipt=[pscustomobject]@{path='receipts/protocol.json';sha256=$sha}}
 $projection=[pscustomobject]@{source_composition=[pscustomobject]@{path='source.json';sha256=$sha};repository_map=[pscustomobject]@{path='map.json';sha256=$sha};feature_lock=[pscustomobject]@{path='feature.json';sha256=$sha}}
 Write-Fixture (Join-Path $workspace 'local/resolver.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.tooling_context_resolver.v1';context_id='fixture-context';executor_root=$tool;routers=@([pscustomobject]@{skill_id='fixture-router';root=$routerRoot});status='resolved';does_not_prove=@('Fixture locations only.')})
 $producerArgs=@{WorkspaceRoot=$workspace;ContextId='fixture-context';ProjectId='fixture-project';PreparationId='fixture-preparation';ProductProjection=$projection;ResolverPath='local/resolver.json';Executor=$executor;Routers=@($router);Compatibility=$compat}
 Denied {New-MorphospaceObservedToolingContext @producerArgs} "Tooling context historical executor closure 'entry.txt' drifted." 'clean-crlf-before-router-or-evidence'
 # The exact LF worktree is also clean. Valid source checks must progress to the real router guard.
 [IO.File]::WriteAllText((Join-Path $tool 'entry.txt'),"entry`n",[Text.UTF8Encoding]::new($false));Git-Read @('add','entry.txt')|Out-Null;$executor.closure[1].sha256=Hash-File (Join-Path $tool 'entry.txt')
 Denied {New-MorphospaceObservedToolingContext @producerArgs} "Tooling context router 'fixture-router' lacks managed provenance." 'exact-lf-reaches-router'
 [IO.Directory]::CreateDirectory($routerRoot)|Out-Null;[IO.File]::WriteAllText((Join-Path $routerRoot 'SKILL.md'),"# Fixture`n",[Text.UTF8Encoding]::new($false));$router.managed_files[0].sha256=Hash-File (Join-Path $routerRoot 'SKILL.md')
 Write-Fixture (Join-Path $routerRoot '.morphospace-skill-source.json') ([pscustomobject]@{schema='rusty.morphospace.local_skill_source.v1';skill_id=$router.skill_id;source_commit=$commit;source_tree_sha256=$sha;source_worktree_dirty=$false;source_files=$router.managed_files})
 $empty='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
 $validation=[pscustomobject]@{schema='rusty.morphospace.workflow.affected_validation_evidence.v1';repository='fixture/workflow';base=[pscustomobject]@{commit=$commit;tree=$tree};head=[pscustomobject]@{commit=$commit;tree=$tree};plan_sha256=$sha;platform='windows';runner=[pscustomobject]@{os_description='Host fixture';powershell_version=$PSVersionTable.PSVersion.ToString()};check_results=@([pscustomobject]@{check_id='fixture-contracts';command_path='entry.txt';command_blob_sha1=$commit;mode='executed';result='pass';started=$true;failure_kind=$null;exit_code=0;timed_out=$false;output_truncated=$false;post_kill_drain_timed_out=$false;stdout_sha256=$empty;stderr_sha256=$empty;stdout_bytes=0;stderr_bytes=0});result='pass';claims=[pscustomobject]@{historical_aggregate_reused=$false;acceptance_authority=$false;publication_authority=$false}}
 Write-Fixture (Join-Path $workspace 'receipts/validation.json') $validation;$binding=[pscustomobject]@{path='receipts/validation.json';sha256=Hash-File (Join-Path $workspace 'receipts/validation.json')}
 Write-Fixture (Join-Path $workspace 'receipts/publication.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.tooling_context_publication_evidence.v1';publication_id='fixture-observed';executor=[pscustomobject]@{repo_id='workflow';remote_url=$executor.remote_url;commit=$commit;tree=$tree};validation=$binding;status='source-observed';does_not_prove=@('Does not independently prove remote publication authority.')})
 $executor.publication_evidence.sha256=Hash-File (Join-Path $workspace 'receipts/publication.json')
 Write-Fixture (Join-Path $workspace 'receipts/protocol.json') ([pscustomobject]@{schema='rusty.morphospace.workflow.tooling_context_protocol_receipt.v1';receipt_id='fixture-protocol';executor=[pscustomobject]@{repo_id='workflow';commit=$commit;tree=$tree};protocol=[pscustomobject]@{protocol_id=$compat.protocol_id;product_lock_schema=$compat.product_lock_schema;repository_map_schema=$compat.repository_map_schema;allowed_actions=$compat.allowed_actions};validation=$binding;status='compatible';does_not_prove=@('Fixture only, no product authority.')})
 $compat.receipt.sha256=Hash-File (Join-Path $workspace 'receipts/protocol.json')
 $context=New-MorphospaceObservedToolingContext @producerArgs
 if(-not(Assert-MorphospaceToolingContextHistoricalObservation -Context $context -WorkspaceRoot $workspace)){throw 'Historical positive failed.'};[Console]::WriteLine('PASS valid-observed-and-historical-producer')
 # A historical cache hit never waives fresh worktree raw bytes or clean identity.
 [IO.File]::WriteAllText((Join-Path $tool 'entry.txt'),"entry`r`n",[Text.UTF8Encoding]::new($false));Git-Read @('add','entry.txt')|Out-Null
 Denied {New-MorphospaceObservedToolingContext @producerArgs} "Tooling context executor closure 'entry.txt' drifted." 'cache-hit-does-not-waive-raw-bytes'
 $executor.closure[1].sha256=Hash-File (Join-Path $tool 'entry.txt')
 Denied {New-MorphospaceObservedToolingContext @producerArgs} "Tooling context historical executor closure 'entry.txt' drifted." 'new-fingerprint-does-not-reuse-cache'
 [IO.File]::WriteAllText((Join-Path $tool 'entry.txt'),"dirty`n",[Text.UTF8Encoding]::new($false))
 Denied {New-MorphospaceObservedToolingContext @producerArgs} 'Tooling context executor Git identity or cleanliness drifted.' 'dirty-before-blob-preflight'
 [Console]::WriteLine('PASS executor-preflight 6 controls; no router installation, staging or lifecycle')
}finally{
 $absolute=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/');if([IO.Path]::GetDirectoryName($absolute).TrimEnd('\','/')-cne$temp-or-not[IO.Path]::GetFileName($absolute).StartsWith('tooling-context-preflight-',[StringComparison]::Ordinal)){throw 'Unsafe fixture cleanup.'};Remove-Item -LiteralPath $absolute -Recurse -Force
}
