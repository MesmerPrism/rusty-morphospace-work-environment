param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
$owner=Import-Module (Join-Path $PSScriptRoot '../lib/MorphospaceNonpassCustodyCorrection.psm1') -PassThru
&$owner {param($w,$p)
    $candidate=Read-MorphospaceProtocolJson $p
    if([string]$candidate.project_id-cne'envelope-test'-or[string]$candidate.unit_id-cne'u002'){throw 'The Return-tuple fixture refuses non-fixture input.'}
    $events=Get-NonpassCustodyEvents $w
    $defect=Read-NonpassCustodyDefect $w $candidate @($events.events)
    # Use genuine immutable rows, but supply a different genuine native event.
    # Its receipt cannot acquire the authorized Return's disposition.
    $caught=$null
    try{Assert-NonpassCustodyReceiptPayloads $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) @($defect.rows) ([string]$candidate.nonpass_custody_defect.begin.event_id)}catch{$caught=$_}
    if($null-eq$caught){throw 'A different native event consumed an authorized failed Return artifact disposition.'}
    if(-not$caught.Exception.Message.Contains('exact retained Return')){throw $caught}
    Assert-NonpassCustodyReceiptPayloads $w ([string]$candidate.nonpass_custody_defect.original_receipt.path) @($defect.rows) ([string]$candidate.nonpass_custody_defect.return.event_id)
    Write-Host 'PASS historical payload disposition requires its authenticated exact Return event.'
} $WorkspaceRoot $RequestPath
