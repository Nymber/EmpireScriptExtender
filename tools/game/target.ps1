<#
  target.ps1 - read and set commodity stockpile targets.

  `target` is how many units of a good to hold back before releasing any to
  trade: below it you keep what you make, at or above it everything is sold.
  0 means sell everything, which is vanilla behaviour and the default.

  Holding stock is not free - chain_sim charges the treasury what selling
  would have earned, because the engine has already paid for the production.

  TWO FILES, ONE WRITER EACH. Stock and targets are plain Lua tables shared
  between the campaign state (which ticks the chain) and the UI state (the
  Stock Controls tab), which cannot call each other. They are separate files
  because chain_sim's flush() rewrites chain_stock.lua WHOLESALE from a copy
  loaded at campaign start - so a target written into it by anyone else mid-
  turn is silently erased at end of turn.

      chain_stock.lua    campaign writes, everyone else reads
      chain_targets.lua  UI and this script write, campaign re-reads each turn

  So this script READS both and WRITES only the targets file. Editing works
  whether or not the game is running.

  Usage
    .\target.ps1                        # show stock and targets
    .\target.ps1 -Set coal=500          # hold 500 coal before selling any
    .\target.ps1 -Set coal=500,steel=200
    .\target.ps1 -Set all=0             # sell everything (vanilla)
#>
param(
    [string]$Set,
    [string]$Faction = "britain",
    [string]$Store,
    [string]$Targets
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $Store) { $Store = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'EmpireScriptExtender\lua\production chains\chain_stock.lua') }
if (-not $Targets) { $Targets = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'EmpireScriptExtender\lua\production chains\chain_targets.lua') }
$ErrorActionPreference = 'Stop'

function Read-Store($path) {
    $d = [ordered]@{}
    if (-not (Test-Path $path)) { return $d }
    foreach ($line in (Get-Content $path)) {
        if ($line -match '^\s*\["([^"]+)"\]\s*=\s*(-?\d+)\s*,?\s*$') { $d[$Matches[1]] = [int]$Matches[2] }
    }
    return $d
}
function Write-Store($path, $d) {
    $out = @("{")
    foreach ($k in ($d.Keys | Sort-Object)) { $out += ('  ["{0}"] = {1},' -f $k, $d[$k]) }
    $out += "}"
    [System.IO.File]::WriteAllLines($path, [string[]]$out, (New-Object System.Text.UTF8Encoding($false)))
}

# Read both, merged for display. Writes below go to $Targets only.
$stockData = Read-Store $Store
$tgtData   = Read-Store $Targets
$data = [ordered]@{}
foreach ($k in $stockData.Keys) { $data[$k] = $stockData[$k] }
foreach ($k in $tgtData.Keys)   { $data[$k] = $tgtData[$k] }

if ($Set) {
    # The goods we know about, so a typo is caught rather than written
    $known = @{}
    foreach ($k in $data.Keys) {
        if ($k -match '^(chain|target)_[^_]+_(res_.+)$') { $known[$Matches[2]] = $true }
    }
    $cfg = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'ese_commodities.txt')
    if (Test-Path $cfg) {
        foreach ($l in (Get-Content $cfg)) {
            if ($l -match '^\s*(res_\S+)\s') { $known[$Matches[1]] = $true }
        }
    }
    # Split on commas OR whitespace: PowerShell reads `-Set a=1,b=2` as an
    # ARRAY argument and binds it to the [string] parameter space-joined, so
    # splitting on commas alone sees one unparseable blob.
    foreach ($pair in ($Set -split '[,\s]+' | Where-Object { $_ })) {
        # Parenthesised, then indexed. `$a, $b = $s -split '='` binds as
        # `$a, ($b = ...)`, so $b became the whole array and [int] threw.
        $parts = @($pair.Trim() -split '=')
        if ($parts.Count -ne 2 -or -not $parts[1]) { throw "expected good=number, got '$pair'" }
        $name = $parts[0]
        $val  = $parts[1]
        $n = [int]$val
        if ($name -eq 'all') {
            foreach ($k in @($data.Keys)) { if ($k -like "target_*") { $data[$k] = $n } }
            "set EVERY target to $n"
            continue
        }
        $good = if ($name -like 'res_*') { $name } else { "res_$name" }
        if ($known.Count -gt 0 -and -not $known.ContainsKey($good)) {
            Write-Host ("WARNING: '{0}' is not a known commodity - writing it anyway, but check the spelling" -f $good) -ForegroundColor Yellow
        }
        $data["target_${Faction}_${good}"] = $n
        "set {0} target -> {1}" -f $good, $n
    }
    # Write ONLY the target keys, and only to the targets file. Writing the
    # merged table back would put a stale copy of the campaign's stock into a
    # file the campaign owns, which is the clobber this split exists to avoid.
    $outT = [ordered]@{}
    foreach ($k in ($data.Keys | Where-Object { $_ -like 'target_*' })) { $outT[$k] = $data[$k] }
    Write-Store $Targets $outT
    ""
}

$rows = @()
foreach ($k in $data.Keys) {
    if ($k -match "^chain_${Faction}_(res_.+)$") {
        $good = $Matches[1]
        $rows += [pscustomobject]@{
            Good   = $good -replace '^res_',''
            Stock  = $data[$k]
            Target = $(if ($data.Contains("target_${Faction}_$good")) { $data["target_${Faction}_$good"] } else { 0 })
        }
    }
}
foreach ($k in $data.Keys) {
    if ($k -match "^target_${Faction}_(res_.+)$") {
        $good = $Matches[1] -replace '^res_',''
        if (-not ($rows | Where-Object { $_.Good -eq $good })) {
            $rows += [pscustomobject]@{ Good = $good; Stock = 0; Target = $data[$k] }
        }
    }
}
if ($rows.Count -eq 0) {
    "no stock recorded yet for '$Faction' - the chain has not ticked with a production source"
    "store: $Store"
} else {
    "{0,-18} {1,8} {2,8}" -f 'good','stock','target'
    foreach ($r in ($rows | Sort-Object Good)) {
        $note = if ($r.Target -eq 0) { 'selling all' } elseif ($r.Stock -ge $r.Target) { 'full - selling' } else { 'holding' }
        "{0,-18} {1,8} {2,8}   {3}" -f $r.Good, $r.Stock, $r.Target, $note
    }
}
