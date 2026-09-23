<#
  game.ps1 - stop, start or restart Empire: Total War, and optionally deploy the
  freshly built ESE DLL and rotate the log in the same step.

  WHY THIS EXISTS
    Every diagnostic cycle is: close the game -> copy dinput8.dll (it is LOCKED
    while the game runs, and the copy fails silently enough to be missed) ->
    clear ese_log.txt so the next run is unambiguous -> launch -> load a
    campaign. Doing that by hand each time is the slowest part of the loop and
    it is where mistakes creep in: deploying to a locked file and then drawing
    conclusions from a stale DLL has already happened once.

    So this does the whole sequence, in the right order, and refuses to continue
    if a step did not actually take effect.

  Usage
    .\game.ps1                          # status only, changes nothing
    .\game.ps1 -Action stop
    .\game.ps1 -Action start
    .\game.ps1 -Action restart
    .\game.ps1 -Action restart -Deploy -RotateLog -Tag rum9
    .\game.ps1 -Action start -Direct    # bypass Steam, launch Empire.exe

  Notes
    -Deploy copies EmpireScriptExtender\src\dinput8.dll into the game root.
      It is only ever done while the game is STOPPED, and the copy is verified
      by length so a locked or partial write cannot pass unnoticed.
    -RotateLog archives ese_log.txt as ese_log.<tag>.<timestamp>.txt and removes
      the original, so the next run's log contains only that run.
    Steam is the default launcher because Empire is a Steam DRM title; -Direct
      exists for the case where Steam is already running and you want to skip
      the bootstrap wait.
#>
param(
    [ValidateSet('status','stop','start','restart')]
    [string]$Action = 'status',
    [switch]$Deploy,
    [switch]$RotateLog,
    [string]$Tag = 'run',
    [switch]$Direct,
    [int]$TimeoutSec = 90,
    [string]$GameDir,
    [string]$SteamExe,
    [string]$AppId = "10500"
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
$paths = & (Join-Path $PSScriptRoot '..\..\..\empire_paths.ps1') -Json | ConvertFrom-Json
if (-not $GameDir) { $GameDir = $paths.GameDir }
if (-not $SteamExe) { $SteamExe = $paths.SteamExe }

$ErrorActionPreference = 'Stop'

$exe    = Join-Path $GameDir 'Empire.exe'
# Toolkit root, not a subfolder of the game. A release can sit anywhere.
$dllSrc = Join-Path $paths.EseDir 'dinput8.dll'
$dllDst = Join-Path $GameDir 'dinput8.dll'
$log    = Join-Path $GameDir 'ese_log.txt'

function Get-Game { Get-Process Empire -ErrorAction SilentlyContinue }

function Show-Status {
    $p = Get-Game
    if ($p) {
        # Responding is meaningless without a main window (early startup), so
        # report it only when there is one.
        $resp = if ($p.MainWindowHandle -ne 0) { if ($p.Responding) { 'responding' } else { 'NOT RESPONDING' } } else { 'starting up' }
        Write-Host ("Empire.exe RUNNING  pid={0}  {1}" -f $p.Id, $resp) -ForegroundColor Green
    } else {
        Write-Host "Empire.exe not running" -ForegroundColor DarkGray
    }
    if (Test-Path $dllDst) {
        $d = Get-Item $dllDst
        $s = if (Test-Path $dllSrc) { (Get-Item $dllSrc).Length } else { $null }
        $mark = if ($s -and $s -eq $d.Length) { 'matches build' } elseif ($s) { "STALE (build is $s bytes)" } else { '' }
        Write-Host ("dinput8.dll  {0} bytes  {1}  {2}" -f $d.Length, $d.LastWriteTime.ToString('HH:mm:ss'), $mark)
    } else {
        Write-Host "dinput8.dll  NOT INSTALLED" -ForegroundColor Yellow
    }
    if (Test-Path $log) { Write-Host ("ese_log.txt  {0} bytes" -f (Get-Item $log).Length) }
}

function Stop-Game {
    $p = Get-Game
    if (-not $p) { Write-Host "already stopped"; return $true }

    Write-Host ("stopping pid {0}..." -f $p.Id) -NoNewline
    # Ask politely first: a clean exit lets the game flush preferences, and a
    # killed process can leave the DLL handle held for a moment longer.
    try { $null = $p.CloseMainWindow() } catch {}

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Get-Game)) { Start-Sleep -Milliseconds 400 }

    if (Get-Game) {
        Write-Host " did not close, killing..." -NoNewline
        try { (Get-Game).Kill() } catch {}
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and (Get-Game)) { Start-Sleep -Milliseconds 400 }
    }

    if (Get-Game) { Write-Host " FAILED" -ForegroundColor Red; return $false }

    # The process being gone is not the same as the DLL being unlocked - wait
    # until it is actually writable, or -Deploy will fail for no visible reason.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try { $fs = [System.IO.File]::Open($dllDst, 'Open', 'ReadWrite', 'None'); $fs.Close(); break }
        catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Host " stopped" -ForegroundColor Green
    return $true
}

function Deploy-Dll {
    if (Get-Game) { Write-Host "REFUSING to deploy while the game is running" -ForegroundColor Red; return $false }
    if (-not (Test-Path $dllSrc)) { Write-Host "no built DLL at $dllSrc" -ForegroundColor Red; return $false }
    Copy-Item $dllSrc $dllDst -Force
    $s = (Get-Item $dllSrc).Length; $d = (Get-Item $dllDst).Length
    if ($s -ne $d) { Write-Host ("deploy MISMATCH: {0} -> {1} bytes" -f $s, $d) -ForegroundColor Red; return $false }
    Write-Host ("deployed dinput8.dll ({0} bytes)" -f $d) -ForegroundColor Green
    return $true
}

function Rotate-Log {
    if (-not (Test-Path $log)) { Write-Host "no ese_log.txt to rotate"; return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dest  = Join-Path $GameDir ("ese_log.{0}.{1}.txt" -f $Tag, $stamp)
    Copy-Item $log $dest -Force
    Remove-Item $log -Force
    Write-Host ("archived log -> {0}" -f (Split-Path $dest -Leaf)) -ForegroundColor Green
}

function Start-Game {
    if (Get-Game) { Write-Host "already running"; return $true }
    if ($Direct) {
        Write-Host "launching Empire.exe directly..." -NoNewline
        Start-Process -FilePath $exe -WorkingDirectory $GameDir | Out-Null
    } else {
        if (-not $SteamExe -or -not (Test-Path $SteamExe)) {
            throw "steam.exe not found. Set STEAM_EXE, or use -Direct to launch Empire.exe."
        }
        Write-Host "launching via Steam (appid $AppId)..." -NoNewline
        # The steam:// handler is what Steam itself uses; it works whether or
        # not the client is already up, unlike calling Empire.exe under DRM.
        Start-Process -FilePath $SteamExe -ArgumentList "-applaunch", $AppId | Out-Null
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and -not (Get-Game)) { Start-Sleep -Milliseconds 500 }
    if (-not (Get-Game)) { Write-Host " TIMED OUT after ${TimeoutSec}s" -ForegroundColor Red; return $false }
    Write-Host (" started, pid {0}" -f (Get-Game).Id) -ForegroundColor Green
    return $true
}

switch ($Action) {
    'status'  { Show-Status }
    'stop'    { $null = Stop-Game; if ($RotateLog) { Rotate-Log }; if ($Deploy) { $null = Deploy-Dll }; Show-Status }
    'start'   {
        # Deploy/rotate before launching, or the run picks up the old DLL.
        if ($Deploy)    { if (-not (Deploy-Dll)) { exit 1 } }
        if ($RotateLog) { Rotate-Log }
        if (-not (Start-Game)) { exit 1 }
    }
    'restart' {
        if (-not (Stop-Game)) { exit 1 }
        if ($Deploy)    { if (-not (Deploy-Dll)) { exit 1 } }
        if ($RotateLog) { Rotate-Log }
        if (-not (Start-Game)) { exit 1 }
    }
}
