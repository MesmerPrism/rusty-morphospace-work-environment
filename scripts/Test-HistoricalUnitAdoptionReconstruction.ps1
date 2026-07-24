param([string]$Path,[string]$WorkspaceRoot,[string]$AnchorRepository,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\MorphospaceHistoricalAdoptionReconstruction.psm1') -Force
if($SelfTest){
 $root=Join-Path ([IO.Path]::GetTempPath()) ('historical-reconstruction-'+[guid]::NewGuid().ToString('N'))
 try{
  New-Item -ItemType Directory -Path (Join-Path $root 'receipts') -Force|Out-Null
  $receipt=[ordered]@{schema='rusty.morphospace.workflow.historical_unit_adoption_receipt.v1';receipt_id='historical-adoption';project_id='example-project';source_workflow=[ordered]@{release='0.1.0';commit=('1'*40)};units=@()}
  $original=Join-Path $root 'receipts\historical-adoption.json';$copy=Join-Path $root 'receipts\historical-adoption-reconstructed.json'
  $receipt|ConvertTo-Json -Depth 8|Set-Content $original -Encoding utf8;Copy-Item $original $copy
  $observed=(Get-FileHash $original -Algorithm SHA256).Hash.ToLowerInvariant();$copyHash=(Get-FileHash $copy -Algorithm SHA256).Hash.ToLowerInvariant()
  $d=Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\historical-unit-adoption-reconstruction.example.json')|ConvertFrom-Json
  $anchor=Join-Path $root 'anchor';New-Item -ItemType Directory $anchor|Out-Null;git -C $anchor init -q;git -C $anchor config user.name fixture;git -C $anchor config user.email fixture@example.invalid
  New-Item -ItemType Directory (Join-Path $anchor 'receipts')|Out-Null;Copy-Item $copy (Join-Path $anchor 'receipts\historical-adoption.json');git -C $anchor -c core.autocrlf=false add .;git -C $anchor commit -q -m anchor
  $revision=(git -C $anchor rev-parse HEAD).Trim();$tree=(git -C $anchor rev-parse 'HEAD^{tree}').Trim();$blob=(git -C $anchor rev-parse 'HEAD:receipts/historical-adoption.json').Trim()
  $d.damaged_original.expected_sha256=('a'*64);$d.damaged_original.observed_sha256=$observed;$d.reconstruction.sha256=$copyHash
  $d.immutable_anchor.repository='source-owner';$d.immutable_anchor.revision=$revision;$d.immutable_anchor.tree=$tree;$d.immutable_anchor.source_blob=$blob;$d.immutable_anchor.content_sha256=$copyHash
  $path=Join-Path $root 'receipts\reconstruction.json';$d|ConvertTo-Json -Depth 12|Set-Content $path -Encoding utf8
  Test-MorphospaceHistoricalAdoptionReconstruction -Path $path -WorkspaceRoot $root -AnchorRepository $anchor|Out-Null
  $d.reconstruction.path=$d.damaged_original.path;$d|ConvertTo-Json -Depth 12|Set-Content $path -Encoding utf8
  $rejected=$false;try{Test-MorphospaceHistoricalAdoptionReconstruction -Path $path -WorkspaceRoot $root -AnchorRepository $anchor|Out-Null}catch{$rejected=$true};if(-not$rejected){throw'Original-path substitution was accepted.'}
  Write-Host 'Historical-unit adoption reconstruction self-test passed.'
 }finally{if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force}}
 return
}
if(-not$Path-or-not$WorkspaceRoot-or-not$AnchorRepository){throw'Path, WorkspaceRoot, and AnchorRepository are required.'}
Test-MorphospaceHistoricalAdoptionReconstruction -Path $Path -WorkspaceRoot $WorkspaceRoot -AnchorRepository $AnchorRepository|ConvertTo-Json -Depth 16
