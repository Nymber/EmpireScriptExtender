<#
  launch_battle.ps1 - start Empire straight into a battle, skipping every menu.

  Empire registers a script command:
      game_startup_mode <battle|campaign|frontend|naval> opt:<xml name>
  and testdata.pack ships ~100 of CA's own development battles, so a battle can
  be booted directly instead of clicking through the frontend.

  THREE TRAPS this script handles, all learned the hard way:
   1. preferences.empire_script.txt is UTF-16LE WITH BOM. Writing UTF-8 makes
      Empire ignore the whole file.
   2. write_preferences_at_exit is true, so Empire REWRITES this file when it
      quits and silently drops our line. The line is therefore re-applied on
      every launch rather than set once.
   3. Editing while the game is running is pointless for the same reason - the
      in-memory copy wins and overwrites on exit. This refuses to run if Empire
      is up.

  Usage
    .\launch_battle.ps1                       # default small land battle
    .\launch_battle.ps1 -Battle testdata/world/lineinfantrybattle.xml
    .\launch_battle.ps1 -List                 # show bundled test battles
    .\launch_battle.ps1 -Restore              # put preferences back, no launch
#>
param(
    [string]$Battle = "testdata/world/lineinfantrybattle.xml",
    [switch]$List,
    [switch]$Restore,
    [switch]$NoLaunch,
    [int]$AppId = 10500
)
$ErrorActionPreference = 'Stop'

$prefs  = Join-Path $env:APPDATA "The Creative Assembly\Empire\scripts\preferences.empire_script.txt"
$backup = "$prefs.bak_prelaunch"
$gameDir = (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet)

if ($List) {
    Write-Host "Bundled test battles worth using (all in testdata.pack):"
    @(
        "testdata/world/lineinfantrybattle.xml      line infantry, small - best for first-person work",
        "testdata/world/smalllandbattle.xml         smallest land battle, fastest load",
        "testdata/world/grenadiersmallbattle.xml    grenadiers, small",
        "testdata/world/balanced_field_battle.xml   larger balanced field battle",
        "testdata/world/demolandbattle.xml          CA demo land battle",
        "testdata/world/fortbattle.xml              fort assault",
        "testdata/world/smallseabattle.xml          naval, small"
    ) | ForEach-Object { Write-Host "  $_" }
    return
}

if (Get-Process Empire -ErrorAction SilentlyContinue) {
    throw "Empire is running. Close it first - it overwrites preferences on exit, so any edit made now is lost."
}
if (-not (Test-Path $prefs)) { throw "preferences not found: $prefs" }

if ($Restore) {
    if (Test-Path $backup) {
        Copy-Item $backup $prefs -Force
        Write-Host "preferences restored from $backup"
    } else {
        Write-Host "no backup to restore"
    }
    return
}

# keep one pristine copy from before we ever touched it
if (-not (Test-Path $backup)) {
    Copy-Item $prefs $backup
    Write-Host "backed up preferences -> $backup"
}

# UTF-16LE in, UTF-16LE out. Read-as-string then WriteAllLines with a
# UnicodeEncoding that emits the BOM.
$lines = [IO.File]::ReadAllLines($prefs, [Text.Encoding]::Unicode)

$modeLine = "game_startup_mode battle $Battle;"
$found = $false
$out = foreach ($l in $lines) {
    if ($l -match '^\s*game_startup_mode\b') { $found = $true; $modeLine }
    elseif ($l -match '^\s*write_preferences_at_exit\b') {
        # leave the user's setting alone but note it - we re-apply each launch
        $l
    }
    else { $l }
}
if (-not $found) { $out = @($out) + $modeLine }

[IO.File]::WriteAllLines($prefs, $out, (New-Object Text.UnicodeEncoding($false, $true)))

$check = [IO.File]::ReadAllBytes($prefs)
if ($check[0] -ne 0xFF -or $check[1] -ne 0xFE) { throw "BOM lost - Empire would ignore this file. Aborting." }
Write-Host ("set: {0}" -f $modeLine)
Write-Host ("preferences {0} bytes, BOM intact (FF FE)" -f $check.Length)

if ($NoLaunch) { Write-Host "(-NoLaunch, not starting)"; return }

Write-Host "launching via steam://rungameid/$AppId ..."
Start-Process "steam://rungameid/$AppId"
Write-Host "Empire should boot straight into: $Battle"
