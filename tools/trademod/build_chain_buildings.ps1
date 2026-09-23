<#
  build_chain_buildings.ps1 - generate the production buildings from the BLD
  lines in chain_manifest.txt.

  THE WIRING (proven by the rum distillery, which builds and produces)
    building_chains                      the chain key
    building_chain_to_slots              WHERE it may be built  <- the localisation
    building_levels                      3 levels, cost/time
    building_culture_variants            per-culture art + description (5 cultures)
    building_description_texts           description keys
    effects                              one commodity_prod_<x> per chain
    building_effects_junction            level -> effect -> output value
    effect_bonus_value_commodity_junction  effect -> the commodity it produces

  All eight files are ADDITIVE (new rows only, zzz_ prefixed), so none of them
  restate a vanilla row and none can duplicate a primary key.

  HOW BUILDINGS RELATE TO UNITS
    Empire gates recruitment natively through building_units_allowed
    (building_level -> unit). That table has a `conditions` column, but it is
    DEAD - all 3,260 vanilla rows read "(none)" - so it cannot express "needs
    gunpowder". Buildings gate units; STOCK does not, natively.

    So there are two layers, and only the first is the engine's:
      1. native : you need a Cannon Works to recruit artillery  (this script)
      2. ours   : you need gunpowder in stock, enforced per turn by
                  add_restricted_unit_record from the ESE script
    Layer 2 is still unproven - add_restricted_unit_record has never been
    called. If it does not work, buildings alone gate units and scarcity has no
    teeth.

  ART is reused from the rum distillery's sugar-plantation pieces because those
  keys are known to exist and resolve. A foundry that looks like a plantation
  is wrong but harmless; swapping in proper art is a cosmetic follow-up, and a
  dangling artpiece FK would be a clean exit before the main menu.

  Usage
    .\build_chain_buildings.ps1 [-Apply]
#>
param(
    [switch]$Apply,
    [string]$Manifest = "$PSScriptRoot\chain_manifest.txt",
    [string]$Staged
)

# Work tree lives next to the toolkit, not on a fixed drive.
if (-not $Staged) { $Staged = Join-Path $env:TEMP 'etw_chain_pack\staged' }

$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
$work  = Join-Path $env:TEMP "etw_chain_bld"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function WriteLines($p, $l) { [System.IO.File]::WriteAllLines($p, [string[]]$l, $utf8NoBom) }

$CULTURES = @('european','indian','middle_east','tribal','tribal_playable')

# ART - referenced, never authored. `artpiece` is an FK into warscape_rigid_tables,
# so we point at models Empire already ships; a dangling key is a clean exit
# before the main menu, which is why only verified strings appear here.
#
# METALWORKS is the right family: these are industrial buildings, and it is the
# only industrial art that exists for all three major cultures at all three
# levels. What Empire does NOT have is a European mine (pit mines are
# NA_/NAN_ only, and only at level 1) or anything ordnance-specific, so mines
# and powder mills borrow the metalworks look too.
#
# NOTE the level-1 European key is LOWERCASE in the shipped data
# ("eu_town_ind_lvl1_metalworks"); the FK is matched literally, so it is spelled
# exactly as the game does rather than normalised.
# tribal/tribal_playable reuse the European art, as the rum distillery does.
# Art FAMILIES, chosen per building by the 7th BLD field. Only families that
# exist for all three major cultures are offered, and the level lists are
# spelled exactly as the shipped data does (note the LOWERCASE "eu_" at level
# 1 - the FK is matched literally).
#
#   metalworks  lvl1-3   foundries, mines, ordnance
#   pottery     lvl1-4   generic workshops (the only family with a level 4)
#   weavers     lvl1-2   ONLY TWO LEVELS - level 3 repeats level 2
#   port        lvl1-4   dockside
#
# tribal/tribal_playable reuse the European art, as the rum distillery does.
# Each family is a FORMAT: {0} culture prefix, {1} level number. The level sits
# in the MIDDLE for the town_ind families and at the END for everything else,
# which is why this is a format string rather than a suffix.
#
# Only families verified to exist for EU, IND and OTT are listed (surveyed from
# vanilla's 451 building_culture_variants rows); the `levels` entry is which
# level numbers actually exist, so asking for one that does not is a build
# error rather than a dangling FK.
$ARTFAMILIES = @{
    metalworks    = @{ fmt = '{0}_town_ind_lvl{1}_metalworks'; levels = @(1,2,3)       }
    pottery       = @{ fmt = '{0}_town_ind_lvl{1}_pottery';    levels = @(1,2,3,4)     }
    weavers       = @{ fmt = '{0}_town_ind_lvl{1}_weavers';    levels = @(1,2)         }
    artillery     = @{ fmt = '{0}_city_artillery_lvl{1}';      levels = @(1,2,3,4,5,6) }
    city_military = @{ fmt = '{0}_city_military_lvl{1}';       levels = @(3,4,5)       }
    city_naval    = @{ fmt = '{0}_city_naval_lvl{1}';          levels = @(1,2,3)       }
    town_military = @{ fmt = '{0}_town_military_lvl{1}';       levels = @(1,3,4)       }
    town_happy    = @{ fmt = '{0}_town_happy_lvl{1}';          levels = @(1,2,3,4)     }
    port_trade    = @{ fmt = '{0}_port_trade_lvl{1}';          levels = @(1,2,3,4)     }
    port_military = @{ fmt = '{0}_port_military_lvl{1}';       levels = @(1,2,3)       }
    port_fishing  = @{ fmt = '{0}_port_fishing_lvl{1}';        levels = @(1,2,3)       }
    furtrader     = @{ fmt = '{0}_resource_furtrader_lvl{1}';  levels = @(1,2,3)       }
    ricepaddy     = @{ fmt = '{0}_resource_ricepaddy_lvl{1}';  levels = @(1,2,3)       }
}

# artpiece is an FK into warscape_rigid_tables, matched LITERALLY, and the
# shipped data is not self-consistent: three European level-1 industrial models
# are spelled eu_* while the icon column spells them EU_*. Only the lowercase
# ones are real models.
#
# So the two columns are resolved differently:
#   artpiece : must exist in warscape_rigid_tables (this list) - a miss is a
#              build error, because at runtime it is a clean exit before the
#              main menu with nothing in any log
#   icon     : the UPPERCASE-prefix spelling, which is what vanilla writes even
#              where the model is lowercase. It is not an FK, so it cannot
#              crash; at worst the picture is missing.
$artFile = Join-Path $tools 'vanilla_artpieces.txt'
if (-not (Test-Path $artFile)) { throw "missing $artFile - see its header for how to regenerate" }
$KNOWNART = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($l in (Get-Content $artFile)) {
    $v = $l.Trim()
    if ($v -and -not $v.StartsWith('#')) { [void]$KNOWNART.Add($v) }
}
Write-Host ("known artpieces: {0}" -f $KNOWNART.Count)

# Resolve one family+level+culture to the exact key the game ships, trying the
# lowercase-prefix spelling as a fallback. $Icon picks the icon column, which
# uses the UPPERCASE prefix even where the model is lowercase.
function Resolve-Art($famName, $lvl, $prefix, [switch]$Icon) {
    $fam = $ARTFAMILIES[$famName]
    if (-not $fam) { throw "unknown art family '$famName' (have: $($ARTFAMILIES.Keys -join ', '))" }
    if ($fam.levels -notcontains $lvl) {
        throw "art family '$famName' has no level $lvl (has: $($fam.levels -join ','))"
    }
    $upper = [string]::Format($fam.fmt, $prefix, $lvl)
    # The icon column always takes the uppercase-prefix spelling, matching
    # vanilla even where the model itself is lowercase. Not an FK.
    if ($Icon) { return $upper }

    if ($KNOWNART.Contains($upper)) { return $upper }
    $lower = [string]::Format($fam.fmt, $prefix.ToLower(), $lvl)
    if ($KNOWNART.Contains($lower)) { return $lower }
    throw "artpiece '$upper' (nor '$lower') exists in warscape_rigid_tables - see vanilla_artpieces.txt"
}
$CULTPREFIX = @{ european='EU'; indian='IND'; middle_east='OTT'; tribal='EU'; tribal_playable='EU' }
$LEVELDEFS = @(
    @{ n=0; tag='small'; word='Small'; omul=1.0; cmul=1.0; time=8  },
    @{ n=1; tag='large'; word='Large'; omul=1.7; cmul=2.0; time=12 },
    @{ n=2; tag='grand'; word='Grand'; omul=2.7; cmul=4.0; time=18 }
)

$blds = @()
foreach ($line in (Get-Content $Manifest)) {
    $s = $line.Trim()
    if ($s -match '^BLD\|') {
        $p = $s -split '\|'
        # 7th field: `family` or `family:l1,l2,l3`
        $artSpec = if ($p.Count -gt 7 -and $p[7]) { $p[7] } else { 'metalworks' }
        $famName, $lvlSpec = $artSpec -split ':', 2
        if (-not $ARTFAMILIES.ContainsKey($famName)) {
            throw "unknown art family '$famName' for $($p[1]) (have: $($ARTFAMILIES.Keys -join ', '))"
        }
        $artLevels = if ($lvlSpec) { @($lvlSpec -split ',' | ForEach-Object { [int]$_.Trim() }) } else { @(1,2,3) }
        if ($artLevels.Count -ne 3) { throw "$($p[1]): art needs exactly 3 levels, got $($artLevels.Count)" }

        $cat = if ($p.Count -gt 8 -and $p[8]) { $p[8] } else { 'money' }

        # 9th field: economic=N / military=N / naval=N, applied to GRAND only
        $prestige = @{ military=0; naval=0; economic=0; enlightenment=0 }
        if ($p.Count -gt 9 -and $p[9]) {
            foreach ($bit in ($p[9] -split ',')) {
                $k, $v = $bit.Trim() -split '='
                if (-not $prestige.ContainsKey($k)) { throw "$($p[1]): unknown prestige '$k'" }
                $prestige[$k] = [int]$v
            }
        }
        # A chain may occupy SEVERAL slot types - the rum distillery is
        # buildable on both `caribbean` and `cuba`. Written as slot+slot.
        $slots = @($p[2] -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        # 10th field: the level-name stem, when it differs from the chain key.
        # The rum chain is `rum` but its levels are small/large/grand_rum_
        # distillery, and both spellings are already referenced by the shipped
        # description keys and by anything built in an existing campaign.
        $stem = if ($p.Count -gt 10 -and $p[10]) { $p[10] } else { $p[1] }

        $blds += [pscustomobject]@{
            Chain=$p[1]; Slots=$slots; Com=$p[3]; Out=[int]$p[4]; Cost=[int]$p[5]; Name=$p[6]
            Fam=$famName; ArtLevels=$artLevels; Category=$cat; Prestige=$prestige; Stem=$stem
        }
    }
}
if (-not $blds) { throw "no BLD lines in $Manifest" }
Write-Host ("{0} building chain(s)" -f $blds.Count)

# PROD lines attach a commodity_prod_ effect to a VANILLA building level, which
# is how res_iron / res_timber / res_corn get produced at all: vanilla ships
# commodity_prod_ effects for only seven goods and none for those three, so
# promoting them to commodities left them with no producer and steel could
# never be made. Every row emitted is additive - a junction against an existing
# building level, never a modified vanilla row.
$prods = @()
foreach ($line in (Get-Content $Manifest)) {
    $s2 = $line.Trim()
    if ($s2 -match '^PROD\|') {
        $p = $s2 -split '\|'
        if ($p.Count -lt 4) { throw "bad PROD line: $s2" }
        $prods += [pscustomobject]@{ Level=$p[1]; Com=$p[2]; Out=[int]$p[3] }
    }
}
Write-Host ("{0} vanilla-building production row(s)" -f $prods.Count)

# ---- validate the slots exist ----------------------------------------------
$slotFile = Join-Path $Staged 'db\slots_tables\slots'
if (-not (Test-Path $slotFile)) { throw "run build_chain_content.ps1 first - $slotFile is missing" }
$validSlots = & "$tools\dbdump.ps1" -File $slotFile -Max 200 |
              Where-Object { $_ -match '^\s{2}\S' -and $_ -notmatch '^\s*(table|columns|\.\.\.)' } |
              ForEach-Object { ($_.Trim() -split '\s*\|\s*')[0] }
$bad = @()
foreach ($b in $blds) {
    foreach ($sl in $b.Slots) { if ($validSlots -notcontains $sl) { $bad += "$($b.Chain)->$sl" } }
}
if ($bad) { throw "unknown slot(s): " + ($bad -join ', ') }
Write-Host ("slots OK ({0} known)" -f $validSlots.Count)

# ---- build every row set ----------------------------------------------------
$chains=@(); $toSlots=@(); $lvlRows=@(); $upg=@(); $variants=@(); $descs=@(); $effects=@(); $effJunc=@(); $comJunc=@(); $locs=@()

foreach ($b in $blds) {
    $eff = "commodity_prod_" + ($b.Com -replace '^res_','')
    $chains  += "{0}|(none)|(none)|{1}" -f $b.Chain, $b.Category
    foreach ($sl in $b.Slots) { $toSlots += "{0}|{1}" -f $b.Chain, $sl }
    $effects += "{0}|data/ui/campaign ui/pips/effect_economy.tga|400" -f $eff
    $comJunc += "{0}|production|{1}" -f $eff, $b.Com

    foreach ($L in $LEVELDEFS) {
        $lvl  = "{0}_{1}" -f $L.tag, $b.Stem
        $out  = [int][math]::Round($b.Out  * $L.omul)
        $cost = [int][math]::Round($b.Cost * $L.cmul)
        # 24 columns, matching building_levels_tables v0
        # Prestige lands on the GRAND level only, as vanilla does. Every other
        # numeric column stays 0 - NOT a placeholder: upkeep_cost, gdp,
        # happiness, pop_change, commodity and commodity_vol are zero in ALL
        # 233 vanilla rows, so the engine does not read them. A building's real
        # economic effect comes through building_effects_junction.
        $isGrand = ($L.n -eq 2)
        $pm = if ($isGrand) { $b.Prestige['military']      } else { 0 }
        $pn = if ($isGrand) { $b.Prestige['naval']         } else { 0 }
        $pe = if ($isGrand) { $b.Prestige['economic']      } else { 0 }
        $px = if ($isGrand) { $b.Prestige['enlightenment'] } else { 0 }
        $lvlRows += ("{0}|{1}|{2}||{3}|{4}|0|0|0|0|0|0|0|0|0|0|||0|False|{5}|{6}|{7}|{8}" -f `
                    $lvl, $b.Chain, $L.n, $L.time, $cost, $pm, $pn, $pe, $px)
        $effJunc += "{0}|{1}|{2}" -f $lvl, $eff, $out
        $descKey = "{0}_european" -f $lvl
        $descs   += $descKey
        $artLvl = $b.ArtLevels[$L.n]
        foreach ($c in $CULTURES) {
            $pre  = $CULTPREFIX[$c]
            $art  = Resolve-Art $b.Fam $artLvl $pre
            $icon = Resolve-Art $b.Fam $artLvl $pre -Icon
            $variants += "{0}|{1}|(none)|{2}|(none)|{3}|{4}" -f $lvl, $c, $art, $descKey, $icon
        }
        # ONE NAME PER CULTURE. The loc key for this table is the composite
        # primary key with NO separator - <building><culture> - so a row for
        # `indian` needs `..._small_coal_mineindian`. Emitting only the
        # European spelling left the other four cultures with a blank name,
        # which is invisible until you play a non-European faction. Vanilla
        # ships a name for every culture it has a variant row for.
        foreach ($c in $CULTURES) {
            $locs += "building_culture_variants_name_{0}{1}|{2} {3}" -f $lvl, $c, $L.word, $b.Name
        }
    }
    # WITHOUT THESE the higher levels are unreachable - you can build level 1
    # and never upgrade it. building_upgrades_junction is what links them.
    for ($i = 0; $i -lt $LEVELDEFS.Count - 1; $i++) {
        $upg += "{0}_{1}|{2}_{1}" -f $LEVELDEFS[$i].tag, $b.Stem, $LEVELDEFS[$i+1].tag
    }
}

# ---- vanilla buildings that now produce a raw commodity --------------------
# One effect per commodity (shared across that commodity's building levels),
# then one junction row per level. The effect and its commodity link are only
# emitted if this run has not already created them for a chain building.
$seenEff = @{}
foreach ($e in $effects) { $seenEff[($e -split '\|')[0]] = $true }
foreach ($p in $prods) {
    $eff = "commodity_prod_" + ($p.Com -replace '^res_','')
    if (-not $seenEff.ContainsKey($eff)) {
        $effects += "{0}|data/ui/campaign ui/pips/effect_economy.tga|400" -f $eff
        $comJunc += "{0}|production|{1}" -f $eff, $p.Com
        $seenEff[$eff] = $true
    }
    $effJunc += "{0}|{1}|{2}" -f $p.Level, $eff, $p.Out
}
if ($prods) {
    Write-Host ("  raw production: {0} level(s) across {1} commodity(ies)" -f `
        $prods.Count, ($prods | ForEach-Object { $_.Com } | Sort-Object -Unique).Count)
}

# ---- what each building level produces, for the ESE chain ------------------
# chain_sim derives a faction's production by asking the engine which of these
# buildings it owns; without this table it would have to guess, or read engine
# memory. Generated here so it cannot drift from the levels actually shipped.
$prodLua = @("-- generated by build_chain_buildings.ps1 - do not edit by hand",
             "-- level_name -> { com = <commodity>, out = <units per turn> }",
             "return {")
foreach ($b in $blds) {
    foreach ($L in $LEVELDEFS) {
        $lvl = "{0}_{1}" -f $L.tag, $b.Stem
        $out = [int][math]::Round($b.Out * $L.omul)
        $prodLua += "  ['$lvl'] = { com = '$($b.Com)', out = $out },"
    }
}
foreach ($p in $prods) {
    $prodLua += "  ['$($p.Level)'] = { com = '$($p.Com)', out = $($p.Out) },"
}
$prodLua += "}"
# Mods are folders under EmpireScriptExtender\lua. $Staged is a temp tree, so
# '..\chain_buildings.lua' used to land next to the generators and get copied
# by hand. Write into the mod folder the loader actually runs.
$prodPath = Join-Path $PSScriptRoot '..\..\lua\production chains\chain_buildings.lua'
WriteLines $prodPath $prodLua
Write-Host ("building outputs -> {0} ({1} levels)" -f (Resolve-Path $prodPath), ($prodLua.Count - 4))

Write-Host ""
Write-Host ("upgrades {0}  chains {1}  slots {2}  levels {3}  variants {4}  descs {5}  effects {6}  eff_junc {7}  com_junc {8}  loc {9}" -f `
    $upg.Count, $chains.Count, $toSlots.Count, $lvlRows.Count, $variants.Count, $descs.Count, $effects.Count, $effJunc.Count, $comJunc.Count, $locs.Count)

if (-not $Apply) { Write-Host "`nDRY RUN - pass -Apply to write"; $lvlRows | Select-Object -First 2 | ForEach-Object { "  $_" }; return }

$targets = @(
    @{ T='building_upgrades_junction_tables';          F='zzz_chain_buildings_upgrades'; R=$upg     },
    @{ T='building_chains_tables';                        F='zzz_chain_buildings_chains';   R=$chains   },
    @{ T='building_chain_to_slots_tables';                F='zzz_chain_buildings_slots';    R=$toSlots  },
    @{ T='building_levels_tables';                        F='zzz_chain_buildings_levels';   R=$lvlRows   },
    @{ T='building_culture_variants_tables';              F='zzz_chain_buildings_variants'; R=$variants },
    @{ T='building_description_texts_tables';             F='zzz_chain_buildings_descs';    R=$descs    },
    @{ T='effects_tables';                                F='zzz_chain_buildings_effects';  R=$effects  },
    @{ T='building_effects_junction_tables';              F='zzz_chain_buildings_effjunc';  R=$effJunc  },
    @{ T='effect_bonus_value_commodity_junction_tables';  F='zzz_chain_buildings_comjunc';  R=$comJunc  }
)
foreach ($t in $targets) {
    $dir = Join-Path $Staged ("db\" + $t.T)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $in = Join-Path $work ("gen_" + $t.F + ".txt")
    WriteLines $in $t.R
    & "$tools\dbgen.ps1" -Table $t.T -In $in -Out (Join-Path $dir $t.F)
    if ($LASTEXITCODE -ne 0) { throw "dbgen failed for $($t.T)" }
}
WriteLines (Join-Path $Staged '..\chain_building_names.txt') $locs
Write-Host ""
Write-Host ("loc entries for the building names -> {0}" -f (Join-Path $Staged '..\chain_building_names.txt'))
& "$tools\dbcheck.ps1" -Path (Join-Path $Staged 'db') | Select-Object -Last 16
