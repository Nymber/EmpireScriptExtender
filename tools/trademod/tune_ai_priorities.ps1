<#
  tune_ai_priorities.ps1 - make the campaign AI care about industry and trade.

  THE PROBLEM
    With production chains, a faction that ignores industry and trade cannot
    field armies. The Grand Campaign AI ("FULL" manager) weights expansion and
    defence far above building anything:

      REGION_GROUP_EXPANSION  3000
      REGION_DEFENCE          2000
      NAVY_STRENGTH_MANAGER   1750
      TRADE_AREA_BEHAVIOUR    1500
      ...
      REGIONAL_DEVELOPMENT     500   <- building up a province
      TRADE_BEHAVIOUR          500   <- actually trading
      TAXATION                 500

    Left alone it will be strangled by a supply chain it does not understand,
    and "the player is constrained and the AI is not" is worse than shipping
    nothing.

  WHAT WE CAN AND CANNOT DO
    We CANNOT teach the native region-valuation code about coal or saltpetre -
    that logic is compiled and takes no data.

    We do not need to. `resources_tables.trade_value` is a region wealth bonus
    (vanilla: corn 25, gems 50, gold 75, iron 30; commodities 0), and the AI
    ALREADY prefers wealthy regions. Giving the new raw materials a trade_value
    makes coal/saltpetre/lead regions objectively more valuable, so the AI
    notices them through machinery it already runs. That half is done in
    chain_manifest.txt.

    What remains is making it build and trade rather than only conquer, which
    is exactly what these priorities control.

  WHY A FULL REPLACEMENT
    campaign_ai_manager_behaviour_junctions is keyed on (manager, behaviour),
    so an additive file restating a row duplicates the key. The table is
    regenerated whole - which is only safe because dbgen -Verify proves it can
    reproduce the shipped table byte for byte first.

  Usage
    .\tune_ai_priorities.ps1                 # show current values, change nothing
    .\tune_ai_priorities.ps1 -Apply
#>
param(
    [switch]$Apply,
    [string]$Staged,
    [string]$SourcePack = "patch.pack"     # the latest copy wins; patch.pack is newest here
)

$ErrorActionPreference = 'Stop'
if (-not $Staged) { $Staged = Join-Path $env:TEMP 'etw_chain_pack\staged' }
$tools = $PSScriptRoot
$work  = Join-Path $env:TEMP "etw_ai_tune"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$tbl = "campaign_ai_manager_behaviour_junctions"
$dir = Join-Path $work "${tbl}_tables"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
& "$tools\packtool.ps1" -Pack $SourcePack -Find "db\${tbl}_tables\$tbl" -Extract -Out $work 2>&1 | Out-Null
$flat = Join-Path $work "db_${tbl}_tables_$tbl"
if (-not (Test-Path $flat)) { throw "could not extract $tbl from $SourcePack" }
Copy-Item $flat (Join-Path $dir $tbl) -Force

$rows = & "$tools\dbdump.ps1" -File (Join-Path $dir $tbl) -Max 2000 |
        Where-Object { $_ -match '^\s{2}\S' -and $_ -notmatch '^\s*(table|columns|\.\.\.)' } |
        ForEach-Object { ($_.Trim() -replace '\s*\|\s*', '|') }
Write-Host ("$tbl : {0} rows from {1}" -f $rows.Count, $SourcePack)

# prove we can reproduce it before replacing it
$vin = Join-Path $work "verify.txt"
[System.IO.File]::WriteAllLines($vin, [string[]]$rows, $utf8NoBom)
& "$tools\dbgen.ps1" -Table "${tbl}_tables" -In $vin -Verify (Join-Path $dir $tbl) | Out-Null
if ($LASTEXITCODE -ne 0) { throw "cannot round-trip $tbl - refusing to ship a full replacement" }
Write-Host "round-trip OK" -ForegroundColor Green

# ---- the changes -----------------------------------------------------------
# Raised, not maximised. Expansion should still dominate - this is a war game -
# but development and trade must be worth doing. These are a starting point to
# be judged against how the AI actually plays, not tuned by argument.
$bump = @{
    'REGIONAL_DEVELOPMENT' = 1500   # 500  -> build up provinces (mines, foundries)
    'TRADE_BEHAVIOUR'      = 1500   # 500  -> seek trade partners for inputs
    'TRADE_AREA_BEHAVIOUR' = 1750   # 1500 -> contest the trade theatres
    'TRADE_ROUTE_DEFENCE'  = 1000   # 750  -> protect what it depends on
    'TAXATION'             =  750   # 500  -> fund the above
}

$out = @(); $changed = @()
foreach ($r in $rows) {
    $f = $r -split '\|'
    if ($bump.ContainsKey($f[1])) {
        $old = [int]$f[2]
        $new = [int]$bump[$f[1]]
        if ($old -ne $new) { $changed += ("{0,-28} {1,-24} {2} -> {3}" -f $f[0], $f[1], $old, $new) }
        $f[2] = $new
    }
    $out += ($f -join '|')
}

Write-Host ""
Write-Host ("{0} row(s) re-weighted:" -f $changed.Count)
$changed | Where-Object { $_ -match '^FULL' } | ForEach-Object { Write-Host "  $_" }
$others = @($changed | Where-Object { $_ -notmatch '^FULL' })
if ($others) { Write-Host ("  ... and {0} more across the other managers" -f $others.Count) }

if (-not $Apply) { Write-Host "`nDRY RUN - pass -Apply to write"; return }

$dest = Join-Path $Staged "db\${tbl}_tables"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$gin = Join-Path $work "gen.txt"
[System.IO.File]::WriteAllLines($gin, [string[]]$out, $utf8NoBom)
& "$tools\dbgen.ps1" -Table "${tbl}_tables" -In $gin -Out (Join-Path $dest $tbl)
if ($LASTEXITCODE -ne 0) { throw "dbgen failed" }
& "$tools\dbcheck.ps1" -Path (Join-Path $Staged 'db') | Select-Object -Last 8
