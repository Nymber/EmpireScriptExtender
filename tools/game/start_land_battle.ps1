<#
Start the ordinary single-player Land Battle flow through the Empire UI.

Sequence: Main Menu > Single Player > Play Battle > Land > Continue >
accept default Army Setup > End Deployment. Does not use bundled testdata
battle files.

The click positions are normalized from the tested 1920x1080 game window and
scaled to the current Empire window rectangle. Keep Empire in its usual
maximized window and at the main menu before starting this script.
#>
[CmdletBinding()]
param(
    [ValidateRange(0,300)][int]$InitialDelaySeconds = 15,
    [ValidateRange(0.1,10)][double]$ClickIntervalSeconds = 0.5,
    [ValidateRange(0,30)][double]$ScreenSettleSeconds = 8.0,
    [ValidateRange(10,300)][int]$BattleLoadTimeoutSeconds = 60,
    [ValidateRange(1,120)][int]$WindowWaitSeconds = 30
)
$ErrorActionPreference = 'Stop'

if (-not ('EmpireBattleUi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EmpireBattleUi {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool PostMessage(IntPtr hwnd, uint msg, UIntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x,int y) { X=x; Y=y; } }
}
'@
}

$deadline = [DateTime]::UtcNow.AddSeconds($WindowWaitSeconds)
$p = $null
$hwnd = [IntPtr]::Zero
do {
    $p = Get-Process Empire -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        $p.Refresh()
        $hwnd = $p.MainWindowHandle
    }
    if ($hwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 500
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $p) { throw 'Empire did not start before the window wait expired.' }
if ($hwnd -eq [IntPtr]::Zero) { throw "Empire did not create its main window within $WindowWaitSeconds seconds." }
$client = New-Object EmpireBattleUi+RECT
if (-not [EmpireBattleUi]::GetClientRect($hwnd, [ref]$client)) { throw 'Could not read Empire client area.' }
$width = $client.Right - $client.Left
$height = $client.Bottom - $client.Top
if ($width -lt 800 -or $height -lt 600) { throw "Empire client area is too small ($width x $height); maximize it first." }

Write-Host "Empire client area found ($width x $height). Bring it to the main menu; battle entry begins in $InitialDelaySeconds seconds."
[void][EmpireBattleUi]::SetForegroundWindow($hwnd)
Start-Sleep -Seconds $InitialDelaySeconds

function Invoke-GameClick([double]$xRef, [double]$yRef, [string]$label) {
    # Reference screenshots are 1920x1080; game content occupies the client
    # area beginning at desktop pixel (8,32) in that reference window.
    $pt = New-Object EmpireBattleUi+POINT
    $pt.X = [int][math]::Round(($xRef - 8) * $width / 1912.0)
    $pt.Y = [int][math]::Round(($yRef - 32) * $height / 1048.0)
    $clientX, $clientY = $pt.X, $pt.Y
    # Send client-coordinate mouse messages directly to Empire. This avoids a
    # screen-coordinate conversion that fails for the game's borderless
    # fullscreen window; PostMessage still targets the intended game HWND.
    [void][EmpireBattleUi]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 250
    $lp = [IntPtr](($clientY -shl 16) -bor ($clientX -band 0xFFFF))
    [void][EmpireBattleUi]::PostMessage($hwnd, 0x0200, [UIntPtr]::Zero, $lp) # WM_MOUSEMOVE
    [void][EmpireBattleUi]::PostMessage($hwnd, 0x0201, [UIntPtr]1, $lp)     # WM_LBUTTONDOWN
    Start-Sleep -Milliseconds 80
    [void][EmpireBattleUi]::PostMessage($hwnd, 0x0202, [UIntPtr]::Zero, $lp) # WM_LBUTTONUP
    Write-Host "Clicked $label"
    Start-Sleep -Milliseconds ([int]($ClickIntervalSeconds * 1000))
}

# Coordinates are button centers from the verified 1920x1080 session.
Invoke-GameClick 967 422 'Single Player'
Start-Sleep -Milliseconds ([int]($ScreenSettleSeconds * 1000))
Invoke-GameClick 967 596 'Play Battle'
Start-Sleep -Milliseconds ([int]($ScreenSettleSeconds * 1000))
Invoke-GameClick 693 493 'Land'
Start-Sleep -Milliseconds ([int]($ScreenSettleSeconds * 1000))
Invoke-GameClick 965 966 'Continue to army setup'
Start-Sleep -Milliseconds ([int]($ScreenSettleSeconds * 1000))
Invoke-GameClick 1544 979 'accept default army setup'

Write-Host "Waiting up to $BattleLoadTimeoutSeconds seconds for the battlefield to load..."
Start-Sleep -Seconds $BattleLoadTimeoutSeconds
if (-not (Get-Process Empire -ErrorAction SilentlyContinue)) { throw 'Empire exited while loading the battle.' }

# End Deployment starts the actual battle. If loading is unusually slow,
# this final click is deliberately delayed by the configurable load timeout.
Invoke-GameClick 962 181 'End Deployment (start battle)'
Write-Host 'Battle start command sent.'
