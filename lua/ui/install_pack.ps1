<#
  Developer helper for the generated HUD button pack.

  This pack is independent of the Lua mod registry. Installing or removing it
  must never edit ese_mods.lua. Generated packs are excluded from releases.

  Usage
    .\install_pack.ps1
    .\install_pack.ps1 -Uninstall
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

if (Get-Process Empire -ErrorAction SilentlyContinue) {
    throw 'Empire is running. Close it before changing UI packs.'
}

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$resolver = [IO.Path]::GetFullPath((Join-Path $here '..\..\empire_paths.ps1'))
if (-not (Test-Path -LiteralPath $resolver)) { throw "missing path resolver: $resolver" }
$game = & $resolver -Quiet
$pack = Join-Path $here 'ese_ui_spawn.pack'
$dest = Join-Path $game 'data\ese_ui_spawn.pack'

if ($Uninstall) {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
        Write-Host 'UI button pack removed. Reload the campaign on the next launch.'
    } else {
        Write-Host 'UI button pack was already absent.'
    }
    return
}

if (-not (Test-Path -LiteralPath $pack)) {
    throw 'The generated ese_ui_spawn.pack is absent. Build it locally first; generated packs are not shipped in ESE releases.'
}
Copy-Item -LiteralPath $pack -Destination $dest -Force
$sourceHash = (Get-FileHash $pack -Algorithm SHA256).Hash
$destHash = (Get-FileHash $dest -Algorithm SHA256).Hash
if ($sourceHash -ne $destHash) { throw 'UI pack copy verification failed' }
Write-Host ("UI button pack installed ({0:N0} bytes), hash verified." -f (Get-Item $dest).Length)
Write-Host 'Reload the campaign on the next launch.'
