<#
  Sends Escape five times, 500 ms apart, to the running Empire window.
  Use when a battle has nested pause/exit screens and the game must return to
  the main menu. Does not launch or terminate the game.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 10)][int]$Presses = 5,
    [ValidateRange(100, 5000)][int]$DelayMs = 500
)
$ErrorActionPreference = 'Stop'

$games = @(Get-Process -Name Empire -ErrorAction SilentlyContinue)
if ($games.Count -ne 1) {
    throw "Expected exactly one running Empire process; found $($games.Count)."
}

$shell = New-Object -ComObject WScript.Shell
if (-not $shell.AppActivate($games[0].Id)) {
    throw "Could not activate the Empire window (PID $($games[0].Id))."
}

for ($i = 1; $i -le $Presses; $i++) {
    $shell.SendKeys('{ESC}')
    Write-Host "Sent Escape $i/$Presses"
    if ($i -lt $Presses) { Start-Sleep -Milliseconds $DelayMs }
}
