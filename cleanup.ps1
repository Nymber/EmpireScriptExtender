<#
  cleanup.ps1 - remove obsolete files from the toolkit tree.

  Every target was audited against one question: WHAT BREAKS IF THIS VANISHES?
  Only files with a verified answer of "nothing" are listed, and each carries its
  own evidence string. Things that merely LOOK like scratch but are real inputs
  are in the KEEP notes at the bottom.

  Nothing here deletes outright by default - items go to the Recycle Bin. Empty
  the bin to actually reclaim the space.

  RELEASE POLICY IS .gitignore's JOB, NOT THIS SCRIPT'S
  A release is the git-tracked set. `.gitignore` already excludes `staged/`
  ("extracted vanilla assets and generated packs - the scripts that build them
  stay") and `tools/_scratch/`. So generated packs never reach a release whether
  or not you run this, and `hipoly_build.rb --verify` proves the toolkit rebuilds
  them from vanilla alone. This script only reclaims local disk.

  USAGE
    .\cleanup.ps1                       # dry run: what would go, and why
    .\cleanup.ps1 -Execute              # send it to the Recycle Bin
    .\cleanup.ps1 -Execute -Permanent   # skip the bin (reclaims space now)
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$Permanent
)
$ErrorActionPreference = 'Stop'

# Resolve roots the same way every other script does, rather than assuming the
# folder layout. An earlier version hardcoded 'EmpireScriptExtender\...' onto the
# root; when the kit was reorganised those paths silently matched NOTHING and it
# cheerfully reported "0 MB would be freed" on a tree with 5 GB of cruft in it.
$self = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$E = & (Join-Path $self 'empire_paths.ps1') -Json | ConvertFrom-Json
$Kit = $E.KitDir          # this toolkit (the git repo)
$Tools = $E.ToolsDir      # its parent: SaveParser, RPFM, Ghidra, GhidraProjects
$S = Join-Path $Kit 'staged'

# path, kind, why it is safe to lose
$Targets = @(
    @{ p = Join-Path $Kit 'tools\_scratch'; k = 'dir'
       w = 'Raw memory dumps from the 2026-09-20 scanmem dead end. Nothing reads them: scanmem.ps1 names scanmem_snap.bin only as an OUTPUT default, and points elsewhere. The addresses inside were ASLR-relative to a process that no longer exists, so they are unreproducible AND worthless. Already gitignored.' }

    @{ p = Join-Path $S '_to_deploy\zz_hipoly.pack'; k = 'file'
       w = 'SHA256-verified byte-identical to data/zz_hipoly.pack.' }
    @{ p = Join-Path $S '_to_deploy\zz_rigid.pack'; k = 'file'
       w = 'SHA256-verified byte-identical to data/zz_rigid.pack.' }
    @{ p = Join-Path $S '_to_deploy\zz_chain.pack'; k = 'file'
       w = 'SHA256-verified byte-identical to data/zz_chain.pack.' }

    @{ p = Join-Path $S '_to_deploy\zz_tex2048.pack'; k = 'file'
       w = 'Early 2.8 MB partial, superseded by the deployed 2,975 MB build.' }
    @{ p = Join-Path $S '_to_deploy\zz_textest.pack'; k = 'file'
       w = 'Texture smoke test, superseded by the full tex2048 pack.' }
    @{ p = Join-Path $S '_to_deploy\zz_bonetest.pack'; k = 'file'
       w = 'The 64-bone config PROVEN to fail. Superseded by zz_b59i8.pack, which is deployed and works.' }

    @{ p = Join-Path $S 'pack_hipoly'; k = 'dir'
       w = 'Staged OUTPUT with two recovery paths: hipoly_build.rb regenerates it (and --verify proves it reproduces byte-identically from vanilla packs alone), and it is also inside the deployed zz_hipoly.pack.' }
    @{ p = Join-Path $S 'pack_textest'; k = 'dir'
       w = 'Test DDS staging for the superseded texture experiment.' }

    @{ p = Join-Path $Kit 'bin'; k = 'dir'
       w = 'Stale BUILD OUTPUT: dinput8.dll here is 259,584 bytes from 2026-09-18, while the DEPLOYED dll is 293,888 bytes from 2026-09-22. Untracked by git. empire.ps1 deploy rebuilds from src/ and installs directly, so nothing reads this. NOTE: src/ itself is the REAL ESE source (196,273 bytes, tracked) - never add it here.' }

    @{ p = Join-Path $Tools 'GhidraProjects\new_commodity_pack\rum.loc.bak'; k = 'file'
       w = 'Backup of a .loc from the commodity work; the built pack is deployed.' }
)

# Ghidra query noise: run logs, and outputs that came back EMPTY (the documented
# failure mode when ghidra.ps1 gets the wrong arg shape - a success message and
# a zero-byte file). These live in the PARENT tree, outside the kit's git repo.
$gh = Join-Path $Tools 'GhidraProjects'
if (Test-Path $gh) {
    Get-ChildItem $gh -Filter *.run.log -File -EA SilentlyContinue | ForEach-Object {
        $Targets += @{ p = $_.FullName; k = 'file'; w = 'ghidra run log'; quiet = $true }
    }
    Get-ChildItem $gh -Filter *.txt -File -EA SilentlyContinue |
        Where-Object { $_.Length -eq 0 } | ForEach-Object {
            $Targets += @{ p = $_.FullName; k = 'file'; w = 'empty ghidra output (failed query)'; quiet = $true }
        }
}

function Get-SizeMB($path) {
    if (Test-Path $path -PathType Container) {
        $s = (Get-ChildItem $path -Recurse -File -EA SilentlyContinue | Measure-Object -Sum Length).Sum
    } elseif (Test-Path $path) {
        $s = (Get-Item $path).Length
    } else { return $null }
    if (-not $s) { $s = 0 }
    return $s / 1MB
}

if (-not $Permanent) { Add-Type -AssemblyName Microsoft.VisualBasic }

$total = 0.0
$quietCount = 0
$quietMB = 0.0
$acted = 0
$found = 0

foreach ($t in $Targets) {
    $mb = Get-SizeMB $t.p
    if ($null -eq $mb) { continue }
    $found++
    $total += $mb

    if ($t.quiet) { $quietCount++; $quietMB += $mb }
    else {
        "{0,9:N1} MB  {1}" -f $mb, (Split-Path $t.p -Leaf)
        "              $($t.w)"
        ""
    }

    if ($Execute) {
        if ($Permanent) {
            Remove-Item $t.p -Recurse -Force
        } elseif ($t.k -eq 'dir') {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($t.p, 'DoNotConfirm', 'SendToRecycleBin')
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($t.p, 'DoNotConfirm', 'SendToRecycleBin')
        }
        $acted++
    }
}

if ($quietCount) { "{0,9:N1} MB  + $quietCount ghidra logs / empty query outputs" -f $quietMB; "" }

"-" * 72
# A run that matches nothing is far more likely to mean the paths are wrong than
# that the tree is clean, so say so instead of printing a reassuring zero.
if ($found -eq 0) {
    "NOTHING MATCHED. That usually means the paths are wrong, not that the tree"
    "is clean. Check that these resolve:"
    "  Kit   $Kit"
    "  Tools $Tools"
    return
}
if ($Execute) {
    $how = if ($Permanent) { 'DELETED' } else { 'sent to the Recycle Bin (restorable)' }
    "{0:N0} MB across {1} items {2}" -f $total, $acted, $how
    if (-not $Permanent) { "Empty the Recycle Bin to actually reclaim the space." }
} else {
    "DRY RUN - nothing removed. {0:N0} MB across $found items would be freed." -f $total
    "Run:  .\cleanup.ps1 -Execute            (recoverable, via Recycle Bin)"
    "      .\cleanup.ps1 -Execute -Permanent (reclaims space immediately)"
}

@"

DELIBERATELY KEPT - these look like clutter but are not:

  staged/pack_rigid (1,914 MB)
      The one real judgement call. It is staged output, and zz_rigid.pack is
      deployed and hash-verified - but subdiv_rigid.rb is SINGLE-FILE only and
      hipoly_build.rb covers only unitmodels/*.variant_weighted_mesh. There is
      NO batch driver for these 2,407 rigid models, so the only way back is
      extracting them from the deployed pack one -Find at a time. Write the
      missing rigid driver first; then this becomes safe to drop.

  src/  -  THE ESE SOURCE. Not a duplicate, not a fork.
      ese_proxy.c (196,273 B), build.ps1, ese.def, ese.ps1, launch_battle.ps1,
      all tracked in git. empire_paths.ps1 reports it as EseDir and empire.ps1
      builds from it. An earlier pass of this script listed src/ for deletion
      based on a snapshot taken before the kit was reorganised. It was wrong.

  tools/game/ese.ps1
      Not redundant with src/ese.ps1: this is the copy that 'empire.ps1 sync'
      mirrors into the game folder, because the game reads its own tree. Under
      the project rule, a tool change goes in BOTH.

  staged/_to_deploy/zz_lodbias.pack (16 KB)
      NOT obsolete - pending. Without MIPMAPLODBIAS = -1.0f the 2048 textures
      only reach ~3.4% of the frame. A wanted change that has not shipped.

  tools/engine/lod_range.bin
      Looks like scratch, IS an input - empire.ps1 lod feeds it to lodscale.rb.

  staged/{unitmodels,unitmodels_hipoly,pack_tex2048,pack_lodbias,pack_bonetest,
  hipoly_auto} (~16 MB total)
      Vanilla reference extracts and the inputs/records of documented
      experiments. Too small to be worth the risk of being wrong.

  GhidraProjects/**/~index.bak   (parent tree)
      Ghidra's own repository index. Ghidra manages these; do not touch.

REVERSIBILITY: the kit IS a git repository now (132 tracked files), so a tracked
file is recoverable with 'git restore'. Everything this script targets is either
gitignored or untracked, which is exactly why it goes to the Recycle Bin.
"@
