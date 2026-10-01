param([Parameter(Mandatory)][string]$BaseReceiptPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-BoundedTail([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $count = [int][Math]::Min(8192L, $stream.Length)
            if ($count -eq 0) { return [pscustomobject]@{ state = 'readable'; bytes = 0; last_line = ''; last_milestone = '' } }
            [void]$stream.Seek(-$count, [IO.SeekOrigin]::End)
            $buffer = [byte[]]::new($count)
            $read = $stream.Read($buffer, 0, $count)
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
            $milestones = @($lines | Where-Object { $_ -match 'BUILD_PHASE|Finished\s+|BUILD SUCCESSFUL|BUILD FAILED|^> Task ' })
            return [pscustomobject]@{
                state = 'readable'
                bytes = $stream.Length
                last_line = if ($lines.Count) { $lines[-1].Substring(0, [Math]::Min(200, $lines[-1].Length)) } else { '' }
                last_milestone = if ($milestones.Count) { $milestones[-1].Substring(0, [Math]::Min(200, $milestones[-1].Length)) } else { '' }
            }
        } finally { $stream.Dispose() }
    } catch [IO.IOException] {
        return [pscustomobject]@{ state = 'read_unavailable'; bytes = $null; last_line = ''; last_milestone = '' }
    } catch [UnauthorizedAccessException] {
        return [pscustomobject]@{ state = 'read_unavailable'; bytes = $null; last_line = ''; last_milestone = '' }
    }
}

function Select-ProgressStream([string]$Base,[string]$Kind) {
    $final = "$Base.$Kind.bin"
    $parent = Split-Path -Parent $final
    $name = Split-Path -Leaf $final
    $temporary = @()
    if (Test-Path -LiteralPath $parent -PathType Container) {
        $temporary = @(Get-ChildItem -LiteralPath $parent -File -Filter "$name.*.tmp" | Where-Object { $_.Name -cmatch "^$([regex]::Escape($name))\.[a-f0-9]{32}\.tmp$" })
    }
    $finalExists = Test-Path -LiteralPath $final -PathType Leaf
    if ($finalExists) { return [pscustomobject]@{ path = $final; phase = 'final' } }
    if ($temporary.Count -eq 1) { return [pscustomobject]@{ path = $temporary[0].FullName; phase = 'active_temp' } }
    if ($temporary.Count -gt 1) { return [pscustomobject]@{ path = $null; phase = 'ambiguous_temp' } }
    return [pscustomobject]@{ path = $null; phase = 'absent' }
}

function Read-ProgressStreamSelection([object]$Selection,[string]$Kind) {
    $readback = if ($null -ne $Selection.path) { Read-BoundedTail $Selection.path } else { [pscustomobject]@{ state = 'not_read'; bytes = $null; last_line = ''; last_milestone = '' } }
    $lastWrite = $null
    if ($null -ne $Selection.path) {
        try { $lastWrite = (Get-Item -LiteralPath $Selection.path -ErrorAction Stop).LastWriteTimeUtc.ToString('o') }
        catch { $lastWrite = $null }
    }
    return [ordered]@{
        kind = $Kind
        phase = $Selection.phase
        read_state = $readback.state
        bytes_observed = $readback.bytes
        last_write_utc = $lastWrite
        last_line = $readback.last_line
        last_milestone = $readback.last_milestone
    }
}

$streams = @()
foreach ($kind in @('stdout', 'stderr')) {
    $selection = Select-ProgressStream $BaseReceiptPath $kind
    $streams += Read-ProgressStreamSelection $selection $kind
}
[ordered]@{
    schema = 'rusty.morphospace.quest_build_progress_observation.v1'
    observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    receipt_present = Test-Path -LiteralPath $BaseReceiptPath -PathType Leaf
    streams = $streams
    scope = 'Read-only, bounded raw-stream progress observation. No process, build outcome, receipt, or device claim. Output lines may contain private build text.'
} | ConvertTo-Json -Depth 6
