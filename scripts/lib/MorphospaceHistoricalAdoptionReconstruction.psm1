Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Get-HistoricalReconstructionSha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Test-HistoricalReconstructionPath([string]$Path){
 if([IO.Path]::IsPathRooted($Path)-or$Path-match'\\'-or$Path-match'(^|/)\.\.(/|$)'-or$Path-notmatch'^receipts/[a-z0-9][a-z0-9-]{1,127}\.json$'){throw'Historical reconstruction path is not canonical and receipt-scoped.'}
}
function Test-HistoricalReconstructionSourcePath([string]$Path){
 if([IO.Path]::IsPathRooted($Path)-or$Path-match'\\'-or$Path-match'(^|/)\.\.(/|$)'-or$Path-notmatch'^[A-Za-z0-9._/-]+\.json$'){throw'Historical reconstruction source path is not canonical and repository-relative.'}
}
function Get-HistoricalAnchorBlobSha([string]$Repository,[string]$Blob) {
 $psi=[Diagnostics.ProcessStartInfo]::new('git');$psi.WorkingDirectory=$Repository
 foreach($a in @('cat-file','blob',$Blob)){[void]$psi.ArgumentList.Add($a)}
 $psi.RedirectStandardOutput=$true;$psi.UseShellExecute=$false;$p=[Diagnostics.Process]::Start($psi)
 try{$sha=[Security.Cryptography.SHA256]::Create();$hash=$sha.ComputeHash($p.StandardOutput.BaseStream);$p.WaitForExit();if($p.ExitCode-ne0){throw'Unable to read immutable anchor blob.'};return([Convert]::ToHexString($hash)).ToLowerInvariant()}finally{$p.Dispose()}
}
function Test-MorphospaceHistoricalAdoptionReconstruction {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$AnchorRepository)
 $d=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
 if([string]$d.schema-cne'rusty.morphospace.workflow.historical_unit_adoption_reconstruction.v1'-or[string]$d.status-cne'independent-reconstruction-verified'){throw'Historical adoption reconstruction schema/status is invalid.'}
 foreach($p in @([string]$d.damaged_original.path,[string]$d.reconstruction.path)){Test-HistoricalReconstructionPath $p}
 Test-HistoricalReconstructionSourcePath ([string]$d.immutable_anchor.source_path)
 if([string]$d.damaged_original.path-ceq[string]$d.reconstruction.path){throw'Reconstruction may not replace the damaged original path.'}
 if([string]$d.damaged_original.expected_sha256-ceq[string]$d.damaged_original.observed_sha256){throw'Damage record does not contain hash drift.'}
 if([string]$d.damaged_original.integrity-cne'damaged-original-unavailable'-or[string]$d.reconstruction.claim-cne'independent-reconstruction-not-original-bytes'){throw'Historical damage and reconstruction claims are invalid.'}
 if([string]$d.projection.scope-cne'current-validation-only'-or$d.projection.original_reference_preserved-ne$true-or$d.projection.accepted_evidence_rewritten-ne$false-or$d.projection.current_or_inflight_units_allowed-ne$false-or$d.projection.conflicting_reconstruction_allowed-ne$false){throw'Historical reconstruction projection widens authority.'}
 $original=Join-Path $WorkspaceRoot ([string]$d.damaged_original.path);$reconstruction=Join-Path $WorkspaceRoot ([string]$d.reconstruction.path)
 if(-not(Test-Path -LiteralPath $original -PathType Leaf)-or(Get-HistoricalReconstructionSha $original)-cne[string]$d.damaged_original.observed_sha256){throw'Damaged original observed hash no longer matches.'}
 if(-not(Test-Path -LiteralPath $reconstruction -PathType Leaf)-or(Get-HistoricalReconstructionSha $reconstruction)-cne[string]$d.reconstruction.sha256){throw'Independent reconstruction hash does not match.'}
 $receipt=Get-Content -LiteralPath $reconstruction -Raw|ConvertFrom-Json
 if([string]$receipt.schema-cne'rusty.morphospace.workflow.historical_unit_adoption_receipt.v1'-or[string]$receipt.project_id-cne[string]$d.project_id){throw'Reconstructed adoption receipt identity is invalid.'}
 $tree=(& git -C $AnchorRepository rev-parse "$([string]$d.immutable_anchor.revision)^{tree}").Trim();if($LASTEXITCODE-ne0-or$tree-cne[string]$d.immutable_anchor.tree){throw'Immutable reconstruction anchor tree does not match.'}
 $blob=(& git -C $AnchorRepository rev-parse "$([string]$d.immutable_anchor.revision):$([string]$d.immutable_anchor.source_path)").Trim();if($LASTEXITCODE-ne0-or$blob-cne[string]$d.immutable_anchor.source_blob){throw'Immutable reconstruction anchor blob does not match.'}
 $anchorHash=Get-HistoricalAnchorBlobSha $AnchorRepository $blob
 if($anchorHash-cne[string]$d.immutable_anchor.content_sha256-or$anchorHash-cne[string]$d.reconstruction.sha256){throw 'Immutable anchor bytes do not equal the reconstructed receipt.'}
 return [pscustomobject][ordered]@{document=$d;receipt=$receipt;sha256=Get-HistoricalReconstructionSha $Path}
}
Export-ModuleMember -Function Test-MorphospaceHistoricalAdoptionReconstruction
