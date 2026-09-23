<#
  Capture selected memory fields into the shared JSONL trace format.

  Example field spec: 48=s:007192A0:float
    48             trace key (hex field offset, no meaning asserted)
    s:007192A0     static Ghidra address; ESE adds the live ASLR delta
    float          ESE_ReadFloat; use int for ESE_ReadInt

  Each prompted phase is a controlled segment: enter "stop 0 0", then
  "straight 1 0", then "turn 0 1". Inputs are recorded with every sample.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Fields,
    [string]$Out = 'behavior_trace.jsonl',
    [ValidateRange(1, 1000)][int]$SamplesPerPhase = 30,
    [ValidateRange(50, 10000)][int]$IntervalMs = 250
)
$ErrorActionPreference = 'Stop'

$kitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (Test-Path -LiteralPath (Join-Path $kitRoot 'empire_paths.ps1')) {
    $paths = & (Join-Path $kitRoot 'empire_paths.ps1') -Json | ConvertFrom-Json
    $ese = Join-Path $paths.EseDir 'ese.ps1'
} else {
    # In the game mirror, empire_paths.ps1 and src/ are intentionally not
    # copied. Use the mirrored ESE pipe client beside this collector.
    $ese = Join-Path $kitRoot 'tools\game\ese.ps1'
}
if (-not (Test-Path -LiteralPath $ese)) { throw "ESE pipe client not found: $ese" }

$parsed = @(foreach ($spec in $Fields) {
    if ($spec -notmatch '^(?<key>(?:0x|\+)?[0-9a-fA-F]+)=(?<addr>(?:s:)?(?:0x)?[0-9a-fA-F]+):(?<type>float|int)$') {
        throw "invalid field '$spec'; expected <hex-offset>=<live-hex-or-s:static-hex>:float|int"
    }
    $key = $Matches.key.ToLowerInvariant() -replace '^(0x|\+)', '' -replace '^0+(?=.)', ''
    [pscustomobject]@{ Key = $key; Address = $Matches.addr; Type = $Matches.type }
})
if ($parsed.Count -gt 24) { throw 'Use at most 24 fields per capture; the ESE pipe response is bounded.' }
if (@($parsed.Key | Select-Object -Unique).Count -ne $parsed.Count) { throw 'field keys must be unique' }

$outPath = [IO.Path]::GetFullPath($Out)
$parent = Split-Path -Parent $outPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
if ((Test-Path -LiteralPath $outPath) -and (Get-Item -LiteralPath $outPath).Length -gt 0) {
    throw "trace already exists: $outPath. Choose a new output path so separate captures cannot be mistaken for consecutive frames."
}
$writer = [IO.StreamWriter]::new($outPath, $false, [Text.UTF8Encoding]::new($false))
try {
    $t = 0
    while ($true) {
        $line = Read-Host 'phase fwd turn (example: stop 0 0; q to finish)'
        if ($line -eq 'q' -or $line -eq 'quit') { break }
        $parts = $line -split '\s+'
        if ($parts.Count -ne 3) { Write-Warning 'Enter exactly: phase forward-input turn-input'; continue }
        $fwd = 0.0; $turn = 0.0
        if (-not [double]::TryParse($parts[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fwd) -or
            -not [double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$turn)) {
            Write-Warning 'Inputs must be numeric values.'; continue
        }

        for ($i = 0; $i -lt $SamplesPerPhase; $i++) {
            $calls = foreach ($field in $parsed) {
                if ($field.Type -eq 'float') { $native = 'ESE_ReadFloat' } else { $native = 'ESE_ReadInt' }
                "$native(`"$($field.Address)`")"
            }
            $lua = 'return table.concat({' + ($calls -join ',') + '}, "\t")'
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $response = (& $ese -Battle $lua | Out-String).Trim()
            $cells = $response -split "`t"
            if ($cells.Count -ne $parsed.Count) {
                throw "ESE returned '$response' instead of $($parsed.Count) values. Confirm a battle is running and the ESE battle state is bound."
            }

            $x = [ordered]@{}
            for ($j = 0; $j -lt $parsed.Count; $j++) {
                $cell = $cells[$j].Trim()
                if ($cell -eq 'UNREADABLE' -or $cell -eq '') { $x[$parsed[$j].Key] = $null; continue }
                try {
                    if ($parsed[$j].Type -eq 'float') {
                        $x[$parsed[$j].Key] = [double]::Parse($cell, [Globalization.CultureInfo]::InvariantCulture)
                    } else {
                        $x[$parsed[$j].Key] = [long]::Parse($cell, [Globalization.CultureInfo]::InvariantCulture)
                    }
                } catch { throw "could not parse value '$cell' for +0x$($parsed[$j].Key)" }
            }
            $record = [ordered]@{
                t = $t; phase = $parts[0]
                u = [ordered]@{ fwd = $fwd; turn = $turn }
                x = $x
            }
            # Keep addresses as capture metadata, distinct from offset-keyed x values.
            $addrMap = [ordered]@{}
            foreach ($field in $parsed) { $addrMap[$field.Key] = $field.Address }
            $record['addresses'] = $addrMap
            $writer.WriteLine(($record | ConvertTo-Json -Compress -Depth 5))
            $writer.Flush()
            $t++
            $remaining = $IntervalMs - [int]$timer.ElapsedMilliseconds
            if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        }
        Write-Host "captured $SamplesPerPhase samples for phase '$($parts[0])' (t now $t)"
    }
} finally {
    $writer.Dispose()
}
Write-Host "trace saved to $outPath"
