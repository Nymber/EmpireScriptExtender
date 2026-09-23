<#
  empire_paths.ps1 - locate an Empire: Total War install on ANY machine.

  Resolution order (first hit wins):
    1. $env:EMPIRE_DIR          explicit override
    2. the RUNNING Empire process
    3. Steam registry -> libraryfolders.vdf -> appmanifest_10500.acf
    4. common fallback paths
    5. walk up from this script  (the kit usually sits inside the install)

  PowerShell twin of empire_paths.rb. Anything that needs a path asks here, so
  nothing is hardcoded to one machine.

  USAGE
    .\empire_paths.ps1            # print what it found
    .\empire_paths.ps1 -Json      # machine-readable (this is what empire.ps1 uses)
    .\empire_paths.ps1 -Quiet     # just the game dir

  THE TWO ROOTS, AND WHY BOTH EXIST
    KitDir    this toolkit - the folder holding THIS file. Everything we edit.
    ToolsDir  its parent, the "Total war empire tools" folder, which also holds
              SaveParser, RPFM, Ghidra and the other third-party tools.

  Neither is derived from the game path. An earlier version built them out of
  $game, which quietly assumed the kit is unzipped inside the Steam install -
  it can sit anywhere, and the game can be on another drive.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$AppId = 10500

# $PSScriptRoot is EMPTY inside param(), so this has to happen in the body.
$kit = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Test-Install([string]$dir) {
    if (-not $dir) { return $false }
    return (Test-Path (Join-Path $dir 'Empire.exe'))
}

function Get-SteamRoots {
    $roots = @()
    foreach ($key in @(
            'HKCU:\Software\Valve\Steam',
            'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
            'HKLM:\SOFTWARE\Valve\Steam')) {
        foreach ($val in @('SteamPath', 'InstallPath')) {
            try {
                $p = (Get-ItemProperty -Path $key -Name $val -ErrorAction Stop).$val
                if ($p -and (Test-Path $p)) { $roots += $p }
            } catch { }
        }
    }
    return $roots | Select-Object -Unique
}

function Get-SteamLibraries {
    $libs = @(Get-SteamRoots)
    foreach ($root in @($libs)) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path $vdf)) { continue }
        # Each library block carries a "path" line; full VDF parsing is overkill.
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"(.+?)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if (Test-Path $p) { $libs += $p }
        }
    }
    return $libs | Select-Object -Unique
}

function Find-Game {
    if ($env:EMPIRE_DIR -and (Test-Install $env:EMPIRE_DIR)) {
        return @{ Path = (Resolve-Path $env:EMPIRE_DIR).Path; Source = 'EMPIRE_DIR' }
    }

    $proc = Get-Process Empire -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) {
        $d = Split-Path -Parent $proc.Path
        if (Test-Install $d) { return @{ Path = $d; Source = "running process (pid $($proc.Id))" } }
    }

    foreach ($lib in Get-SteamLibraries) {
        $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (Test-Path $acf) {
            $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"(.+?)"')
            if ($m.Success) {
                $d = Join-Path $lib ('steamapps\common\' + $m.Groups[1].Value)
                if (Test-Install $d) { return @{ Path = $d; Source = "steam library $lib (appmanifest_$AppId)" } }
            }
        }
        $d = Join-Path $lib 'steamapps\common\Empire Total War'
        if (Test-Install $d) { return @{ Path = $d; Source = "steam library $lib" } }
    }

    foreach ($d in @(
            'C:\Program Files (x86)\Steam\steamapps\common\Empire Total War',
            'C:\Program Files\Steam\steamapps\common\Empire Total War',
            'C:\Program Files (x86)\SEGA\Empire Total War')) {
        if (Test-Install $d) { return @{ Path = $d; Source = 'fallback path' } }
    }

    # The kit usually lives inside the install, so walk up looking for Empire.exe.
    $d = $kit
    while ($d) {
        if (Test-Install $d) { return @{ Path = $d; Source = 'walked up from the kit' } }
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }

    return $null
}

$found = Find-Game
if (-not $found) {
    throw "Empire: Total War not found. Set EMPIRE_DIR to the folder containing Empire.exe."
}

$game = $found.Path
$user = Join-Path $env:APPDATA 'The Creative Assembly\Empire'

$Empire = [ordered]@{
    Source      = $found.Source
    GameDir     = $game
    Exe         = Join-Path $game 'Empire.exe'
    DataDir     = Join-Path $game 'data'
    # KitDir is this folder. ToolsDir is its parent, which also holds SaveParser,
    # RPFM and Ghidra - so the two are NOT interchangeable.
    KitDir      = $kit
    ToolsDir    = Split-Path -Parent $kit
    ScriptTools = Join-Path $kit 'tools'
    # The ESE source, build script, ese.ps1 and launch_battle.ps1 all live in src.
    EseDir      = Join-Path $kit 'src'
    Dll         = Join-Path $game 'dinput8.dll'
    EseLog      = Join-Path $game 'ese_log.txt'
    # The game reads its own mirrored copy of the kit; 'empire.ps1 sync' fills it.
    GameKitDir  = Join-Path $game 'EmpireScriptExtender'
    UserDir     = $user
    Prefs       = Join-Path $user 'scripts\preferences.empire_script.txt'
    FxCache     = Join-Path $user 'fx_cache'
    SaveGames   = Join-Path $user 'save_games'
    AppId       = $AppId
}
# make it available to anything that dot-sources this file
Set-Variable -Name Empire -Value $Empire -Scope Global

if ($Quiet) { $Empire.GameDir; return }
if ($Json) { $Empire | ConvertTo-Json -Compress; return }

"Empire found via: $($Empire.Source)"
foreach ($k in $Empire.Keys) {
    if ($k -eq 'Source' -or $k -eq 'AppId') { continue }
    $v = $Empire[$k]
    $mark = if (Test-Path $v) { 'ok' } else { '--' }
    "  {0,-3} {1,-12} {2}" -f $mark, $k, $v
}
"      {0,-12} {1}" -f 'AppId', $Empire.AppId
