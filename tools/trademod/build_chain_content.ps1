<#
  build_chain_content.ps1 - turn chain_manifest.txt into DB tables.

  WHY A GENERATOR
    Production chains need ~11 new commodities, 8 new resources, 3 new slot
    types, 22 demand-junction rows and a set of slot placements. Hand-authoring
    that is how a field ends up the wrong type or a foreign key ends up
    dangling - and a dangling FK makes Empire exit CLEANLY before the main menu
    with no crash record at all. One manifest, one command, every table
    regenerable.

  FULL-TABLE REPLACEMENTS
    Pack DB files are ADDITIVE: same-folder files merge, so restating a vanilla
    row duplicates its primary key. But making res_iron tradeable means
    MODIFYING a vanilla row (it has unit = (none), and a commodity's resource
    must have a unit or the trade UI null-derefs at 0x00A54682).

    So resources_tables and slots_tables ship as FULL REPLACEMENTS: every
    vanilla row, reproduced exactly, plus modifications and additions. That is
    only safe because dbgen.ps1 -Verify proved it can regenerate the vanilla
    tables BYTE-IDENTICALLY first - this script re-runs that check every time
    and refuses if it ever stops holding.

  Usage
    .\build_chain_content.ps1                 # dry run: validate + report
    .\build_chain_content.ps1 -Apply          # write the staged tree
#>
param(
    [switch]$Apply,
    [string]$Manifest = "$PSScriptRoot\chain_manifest.txt",
    [string]$Staged,
    [string]$GameDir
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $GameDir) { $GameDir = (& (Join-Path $PSScriptRoot '..\..\..\empire_paths.ps1') -Quiet) }
if (-not $Staged) { $Staged = Join-Path $env:TEMP 'etw_chain_pack\staged' }

$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
$work  = Join-Path $env:TEMP "etw_chain_build"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function WriteLines($path, $lines) { [System.IO.File]::WriteAllLines($path, [string[]]$lines, $utf8NoBom) }

# ---- read the manifest ------------------------------------------------------
$slots = @(); $units = @{}; $res = @(); $com = @(); $dem = @(); $place = @(); $recipes = @()
foreach ($line in (Get-Content $Manifest)) {
    $s = $line.Trim()
    if (-not $s -or $s.StartsWith('#')) { continue }
    $p = $s -split '\|'
    switch ($p[0]) {
        'SLOT'   { $slots   += ,$p[1..5] }
        'UNIT'   { $units[$p[1]] = $p[2] }
        'RES'    { $res     += ,$p[1..5] }
        'COM'    { $com     += ,$p[1..5] }
        'DEM'    { $dem     += ,$p[1..7] }
        'PLACE'  { $place   += ,$p[1..2] }
        'RECIPE' { $recipes += ,@($p[1..([Math]::Min(6, $p.Count - 1))]) }
        'BLD'    { }   # buildings are build_chain_buildings.ps1's business
        'PROD'   { }   # ...and so is attaching production to vanilla buildings
        default  { throw "unknown manifest verb '$($p[0])' in: $s" }
    }
}
Write-Host ("manifest: {0} slots, {1} unit overrides, {2} resources, {3} commodities, {4} demand rows, {5} placements, {6} recipes" -f `
    $slots.Count, $units.Count, $res.Count, $com.Count, $dem.Count, $place.Count, $recipes.Count)

# ---- pull the vanilla tables we must reproduce -----------------------------
function Get-VanillaRows($pack, $folder, $file) {
    $dst = Join-Path $work $folder
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    & "$tools\packtool.ps1" -Pack $pack -Find "db\$folder\$file" -Extract -Out $work 2>&1 | Out-Null
    $flat = Join-Path $work ("db_{0}_{1}" -f $folder, $file)
    if (-not (Test-Path $flat)) { throw "could not extract db\$folder\$file from $pack" }
    Copy-Item $flat (Join-Path $dst $file) -Force
    $rows = & "$tools\dbdump.ps1" -File (Join-Path $dst $file) -Max 2000 |
            Where-Object { $_ -match '^\s{2}\S' -and $_ -notmatch '^\s*(table|columns|\.\.\.)' } |
            ForEach-Object { ($_.Trim() -replace '\s*\|\s*', '|') }
    return @{ Rows = $rows; Path = (Join-Path $dst $file) }
}

$vSlots = Get-VanillaRows 'main.pack' 'slots_tables' 'slots'
$vRes   = Get-VanillaRows 'main.pack' 'resources_tables' 'resources'
Write-Host ("vanilla: {0} slots, {1} resources" -f $vSlots.Rows.Count, $vRes.Rows.Count)

# ---- PROVE the replacements are faithful before trusting them --------------
# If dbgen cannot reproduce the vanilla table byte for byte, a full replacement
# would silently corrupt rows we did not intend to touch.
foreach ($chk in @(@('slots_tables', $vSlots), @('resources_tables', $vRes))) {
    $in = Join-Path $work ("verify_" + $chk[0] + ".txt")
    WriteLines $in $chk[1].Rows
    & "$tools\dbgen.ps1" -Table $chk[0] -In $in -Verify $chk[1].Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dbgen cannot round-trip vanilla $($chk[0]) - refusing to ship a full replacement" }
    Write-Host ("round-trip OK: {0}" -f $chk[0]) -ForegroundColor Green
}

# ---- validate foreign keys against the real tables -------------------------
$validSlots = @($vSlots.Rows | ForEach-Object { ($_ -split '\|')[0] }) + @($slots | ForEach-Object { $_[0] })
$badBed = @($res | Where-Object { $validSlots -notcontains $_[2] })
if ($badBed) { throw "slot_bed not a known slot: " + (($badBed | ForEach-Object { "$($_[0])->$($_[2])" }) -join ', ') }

$vRegions = Get-VanillaRows 'main.pack' 'regions_tables' 'regions'
$regionKeys = @($vRegions.Rows | ForEach-Object { ($_ -split '\|')[0] })
$badRegion = @($place | Where-Object { $regionKeys -notcontains $_[1] })
if ($badRegion) {
    Write-Host ("WARNING: {0} placement region(s) not in regions_tables and will be DROPPED: {1}" -f `
        $badRegion.Count, (($badRegion | ForEach-Object { $_[1] }) -join ', ')) -ForegroundColor Yellow
    $place = @($place | Where-Object { $regionKeys -contains $_[1] })
}
Write-Host ("foreign keys OK; {0} placement(s) will be written" -f $place.Count)

# ---- primary keys must be unique -------------------------------------------
# A duplicate key is not an error the engine reports - it is a silent data
# problem or a clean exit before the main menu. An edit that replaced one
# region name with another already in the list produced exactly that, and the
# FK check did not see it because both names were individually valid.
function Assert-Unique($name, $keys) {
    $dup = $keys | Group-Object | Where-Object Count -gt 1
    if ($dup) { throw ("duplicate key(s) in {0}: {1}" -f $name, (($dup | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')) }
}
Assert-Unique 'campaign_map_slots' @($place | ForEach-Object { "{0}:{1}:main" -f $_[0], $_[1] })
Assert-Unique 'slots'              @(@($vSlots.Rows | ForEach-Object { ($_ -split '\|')[0] }) + @($slots | ForEach-Object { $_[0] }))
Assert-Unique 'commodities'        @($com | ForEach-Object { $_[0] })
Assert-Unique 'resources'          @(@($vRes.Rows | ForEach-Object { ($_ -split '\|')[0] }) + @($res | ForEach-Object { $_[0] }))
# a commodity's key is an FK into resources - every one must exist there
$allRes = @($vRes.Rows | ForEach-Object { ($_ -split '\|')[0] }) + @($res | ForEach-Object { $_[0] })
$orphan = @($com | Where-Object { $allRes -notcontains $_[0] })
if ($orphan) { throw "commodity with no resource row: " + (($orphan | ForEach-Object { $_[0] }) -join ', ') }
# and it must have a unit, or the trade UI null-derefs at 0x00A54682
$unitOf = @{}
foreach ($r in $vRes.Rows) { $f = $r -split '\|'; $unitOf[$f[0]] = $(if ($units.ContainsKey($f[0])) { $units[$f[0]] } else { $f[1] }) }
foreach ($r in $res) { $unitOf[$r[0]] = $r[1] }
$noUnit = @($com | Where-Object { -not $unitOf[$_[0]] -or $unitOf[$_[0]] -eq '(none)' })
if ($noUnit) { throw "commodity whose resource has NO UNIT (would crash the Trade tab): " + (($noUnit | ForEach-Object { $_[0] }) -join ', ') }
Write-Host "uniqueness + commodity/resource/unit invariants OK" -ForegroundColor Green

# ---- build the row sets -----------------------------------------------------
$outSlots = @($vSlots.Rows) + @($slots | ForEach-Object { ($_ -join '|') })

$outRes = @()
foreach ($r in $vRes.Rows) {
    $f = $r -split '\|'
    if ($units.ContainsKey($f[0])) { $f[1] = $units[$f[0]] }   # promote to tradeable
    $outRes += ($f -join '|')
}
foreach ($r in $res) {
    $outRes += ("{0}|{1}|{2}|{3}|data\UI\Campaign UI\Pips\{4}.tga" -f $r[0], $r[1], $r[2], $r[3], $r[4])
}

$outCom = @($com | ForEach-Object { "{0}|{1}|{2}" -f $_[0], $_[1], $_[2] })
$outDem = @()
foreach ($d in $dem) {
    $outDem += ("{0}|{1}|{2}|{3}" -f $d[0], $d[1], $d[2], $d[3])
    $outDem += ("{0}|{1}|{2}|{3}" -f $d[0], $d[4], $d[5], $d[6])
}
$outPlace = @($place | ForEach-Object { "{0}:{1}:main|{2}|{0}|0|(none)" -f $_[0], $_[1], $_[1] })

Write-Host ""
Write-Host ("slots        : {0} vanilla + {1} new = {2}" -f $vSlots.Rows.Count, $slots.Count, $outSlots.Count)
Write-Host ("resources    : {0} vanilla ({1} re-unitised) + {2} new = {3}" -f $vRes.Rows.Count, $units.Count, $res.Count, $outRes.Count)
Write-Host ("commodities  : {0} new (total in game = 9 + {0} = {1})" -f $outCom.Count, (9 + $outCom.Count))
Write-Host ("demand rows  : {0}" -f $outDem.Count)
Write-Host ("slot places  : {0}" -f $outPlace.Count)

if (-not $Apply) { Write-Host "`nDRY RUN - pass -Apply to write the staged tree"; return }

# ---- emit --------------------------------------------------------------------
$targets = @(
    @{ Table='slots_tables';                       File='slots';                        Rows=$outSlots  },  # full replacement
    @{ Table='resources_tables';                   File='resources';                    Rows=$outRes    },  # full replacement
    @{ Table='commodities_tables';                 File='zzz_chain_commodities';        Rows=$outCom    },
    @{ Table='commodities_demand_junction_tables'; File='zzz_chain_demand';             Rows=$outDem    },
    # 5 fields: master_schema has three v0 definitions for this table (6/5/6)
    # and only the 5-field one matches the shipped data. dbdump finds that by
    # trial; a writer has to be told.
    @{ Table='campaign_map_slots_tables';          File='zzz_chain_map_slots';          Rows=$outPlace; Fields=5 }
)
foreach ($t in $targets) {
    $dir = Join-Path $Staged ("db\" + $t.Table)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $in = Join-Path $work ("gen_" + $t.File + ".txt")
    WriteLines $in $t.Rows
    $fc = if ($t.Fields) { $t.Fields } else { 0 }
    & "$tools\dbgen.ps1" -Table $t.Table -In $in -Out (Join-Path $dir $t.File) -FieldCount $fc
    if ($LASTEXITCODE -ne 0) { throw "dbgen failed for $($t.Table)" }
}

Write-Host ""
& "$tools\dbcheck.ps1" -Path (Join-Path $Staged 'db')

# ---- the recipes, for the ESE script ---------------------------------------
# Build the Lua with interpolation, NOT -f formatting: the braces in Lua table
# syntax are format placeholders and -f chokes on them.
$recipeLua = @("-- generated by build_chain_content.ps1 - do not edit by hand", "return {")
foreach ($r in $recipes) {
    $pairs = @("['$($r[2])'] = $($r[3])")
    if ($r.Count -gt 4 -and $r[4]) { $pairs += "['$($r[4])'] = $($r[5])" }
    $recipeLua += "  { out = '$($r[0])', qty = $($r[1]), inputs = { $($pairs -join ', ') } },"
}
$recipeLua += "}"
WriteLines (Join-Path $PSScriptRoot '..\..\lua\production chains\chain_recipes.lua') $recipeLua

# ---- baseline prices, for costing reserves and imports ---------------------
# chain_sim charges the treasury what selling would have earned, so it needs a
# price. The engine's CURRENT price moves with supply and demand and is only
# reachable from the UI state (trade_info.prices); the campaign side has no
# price condition. Baseline is the honest approximation, and it is the same
# number the DB seeds the market with.
$vanillaPrices = @{
    res_spices = 16; res_tobacco = 11; res_sugar = 12; res_ivory = 24
    res_tea    = 11; res_cotton  = 12; res_coffee = 8; res_furs  = 9
    res_rum    = 10
}
$priceLua = @("-- generated by build_chain_content.ps1 - do not edit by hand",
              "-- commodity -> baseline price per unit", "return {")
foreach ($k in ($vanillaPrices.Keys | Sort-Object)) { $priceLua += "  ['$k'] = $($vanillaPrices[$k])," }
foreach ($c in $com) { $priceLua += "  ['$($c[0])'] = $($c[1])," }
$priceLua += "}"
WriteLines (Join-Path $PSScriptRoot '..\..\lua\production chains\chain_prices.lua') $priceLua

# ---- ese_commodities.txt ---------------------------------------------------
# ESE reads this beside Empire.exe. It is NOT optional decoration:
#   * each line clones a TradeInfo block so the good gets a price in the UI
#   * `raw_resources N` patches the hardcoded 12 at 0x00A04BB5
# Without it the Trade tab null-derefs the moment it opens, because the engine
# scans for twelve unit-less resources and this mod ships nine. It went
# missing once and the crash came straight back, so it is generated here
# rather than hand-maintained.
# Counted from $outRes, the rows actually written to resources_tables - the
# one place that is guaranteed to match what ships. rum's row comes from the
# additive zzz_rum_resources file, which $outRes does not include, so it is
# added here; it has a unit (barrels) and therefore does not affect the count.
$rawCount = @($outRes | Where-Object { $f = $_ -split '\|'; $f[1] -eq '(none)' -or -not $f[1] }).Count
$eseLines = @(
    "# GENERATED by build_chain_content.ps1 - do not hand-edit.",
    "# <db_key>  <ui_name>   -- ui_name MUST match a component under 'world market'",
    "# or Find returns nil, UIComponent(nil) raises, and the WHOLE Trade tab breaks.",
    ""
)
# rum first, and explicitly: it is a commodity in game but has no COM line
# here, because its row ships in the additive zzz_rum_commodities file from
# the original rum pack. Emitting only $com silently dropped it, which would
# have left the market's rum slot with no price block behind it.
$eseLines += ("{0,-22}{1}" -f 'res_rum', 'rum')
foreach ($c in $com) { $eseLines += ("{0,-22}{1}" -f $c[0], $c[3]) }
$eseLines += @(
    "",
    "# Empire hardcodes twelve unit-less 'raw' resources in the Trade tab scan at",
    "# 0x00A04BB5. This mod ships $rawCount, so the count must be patched or the scan",
    "# walks off resources_table and null-derefs. Keep equal to the number of",
    "# resources_tables rows whose unit is (none).",
    "raw_resources $rawCount"
)
$esePath = Join-Path $GameDir 'ese_commodities.txt'
WriteLines $esePath $eseLines
Write-Host ("ese_commodities.txt -> {0} ({1} commodities, raw_resources {2})" -f $esePath, $com.Count, $rawCount)
Write-Host ("prices -> {0} ({1} goods)" -f (Resolve-Path (Join-Path $PSScriptRoot '..\..\lua\production chains\chain_prices.lua')), ($priceLua.Count - 4))
Write-Host ("`nrecipes -> {0}" -f (Resolve-Path (Join-Path $Staged '..\chain_recipes.lua')))
