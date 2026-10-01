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
    }
}

$streams = @()
foreach ($kind in @('stdout', 'stderr')) {
    $final = "$BaseReceiptPath.$kind.bin"
    $parent = Split-Path -Parent $final
    $name = Split-Path -Leaf $final
    $temporary = @()
    if (Test-Path -LiteralPath $parent -PathType Container) {
        $temporary = @(Get-ChildItem -LiteralPath $parent -File -Filter "$name.*.tmp" | Where-Object { $_.Name -cmatch "^$([regex]::Escape($name))\.[a-f0-9]{32}\.tmp$" })
    }
    $path = if (Test-Path -LiteralPath $final -PathType Leaf) { $final } elseif ($temporary.Count -eq 1) { $temporary[0].FullName } else { $null }
    $phase = if (Test-Path -LiteralPath $final -PathType Leaf) { 'final' } elseif ($temporary.Count -eq 1) { 'active_temp' } elseif ($temporary.Count -gt 1) { 'ambiguous_temp' } else { 'absent' }
    $readback = if ($null -ne $path) { Read-BoundedTail $path } else { [pscustomobject]@{ state = 'not_read'; bytes = $null; last_line = ''; last_milestone = '' } }
    $streams += [ordered]@{
        kind = $kind
        phase = $phase
        read_state = $readback.state
        bytes_observed = $readback.bytes
        last_write_utc = if ($path) { (Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') } else { $null }
        last_line = $readback.last_line
        last_milestone = $readback.last_milestone
    }
}
[ordered]@{
    schema = 'rusty.morphospace.quest_build_progress_observation.v1'
    observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    receipt_present = Test-Path -LiteralPath $BaseReceiptPath -PathType Leaf
    streams = $streams
    scope = 'Read-only, bounded raw-stream progress observation. No process, build outcome, receipt, or device claim. Output lines may contain private build text.'
} | ConvertTo-Json -Depth 6
