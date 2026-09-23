<#
  rumtoggle.ps1 - switch the campaign between VANILLA (8 commodities) and RUM
  (9 commodities), so a measurement can be repeated against a known baseline.

  WHY THIS EXISTS
    Twice now a conclusion about "what vanilla does" was reasoned about rather
    than measured, and twice it was wrong - once claiming a dead lookup table
    held real commodity names, once assuming four out-of-bounds stores were
    pure garbage when in the first of the two calls they land on real fields.
    The baseline is one launch away and both ESE hooks are read-only, so there
    is no excuse for guessing. This makes the swap a single command.

  WHAT IT SWITCHES
    data\campaigns\main\startpos.esf   vanilla <-> rum-patched (9 commodities)
    data\rum_commodity.pack            present <-> parked in .disabled

  Both startpos variants are kept as .bak files and verified by SHA256 before
  anything is overwritten, so a wrong file can never be installed silently.

  Usage
    .\rumtoggle.ps1 -State vanilla
    .\rumtoggle.ps1 -State rum
    .\rumtoggle.ps1               # report which is installed, change nothing
#>
param(
    [ValidateSet('vanilla','rum','status')]
    [string]$State = 'status',
    [string]$GameDir
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $GameDir) { $GameDir = (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) }

$ErrorActionPreference = 'Stop'

$main     = Join-Path $GameDir 'data\campaigns\main'
$live     = Join-Path $main 'startpos.esf'
$vanBak   = Join-Path $main 'startpos.esf.pre_rum_edit.bak'
$rumBak   = Join-Path $main 'startpos.esf.rum9demand.bak'
$pack     = Join-Path $GameDir 'data\rum_commodity.pack'
$packOff  = Join-Path $GameDir 'data\rum_commodity.pack.disabled'

# The two known-good hashes. Anything else means someone edited a file and the
# script must not guess which is which.
$VANILLA_SHA = '7F2E02AD4712A035'
$RUM_SHA     = 'D740BDB5F543E65F'

function Short-Hash([string]$p) {
    if (-not (Test-Path $p)) { return $null }
    (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0,16)
}

function Describe([string]$h) {
    switch ($h) {
        $VANILLA_SHA { 'VANILLA (8 commodities)' }
        $RUM_SHA     { 'RUM (9 commodities, arrays + demand)' }
        $null        { 'MISSING' }
        default      { "UNKNOWN ($h)" }
    }
}

# Refuse while the game holds the files - a half-done swap is the worst state.
if (Get-Process Empire -ErrorAction SilentlyContinue) {
    Write-Host "Empire.exe is running - close it first." -ForegroundColor Red
    exit 1
}

$liveHash = Short-Hash $live
Write-Host ("startpos.esf : {0}" -f (Describe $liveHash))
Write-Host ("rum pack     : {0}" -f $(if (Test-Path $pack) { 'INSTALLED' } elseif (Test-Path $packOff) { 'disabled' } else { 'MISSING' }))

if ($State -eq 'status') { return }

# Verify the backup we are about to install really is what it claims.
$want    = if ($State -eq 'vanilla') { $VANILLA_SHA } else { $RUM_SHA }
$srcBak  = if ($State -eq 'vanilla') { $vanBak }      else { $rumBak }
$srcHash = Short-Hash $srcBak
if ($srcHash -ne $want) {
    Write-Host ("REFUSING: {0} has hash {1}, expected {2}" -f (Split-Path $srcBak -Leaf), $srcHash, $want) -ForegroundColor Red
    exit 1
}

# Keep whichever variant is live as its own backup before overwriting it.
if ($liveHash -eq $VANILLA_SHA -and -not (Test-Path $vanBak)) { Copy-Item $live $vanBak }
if ($liveHash -eq $RUM_SHA     -and -not (Test-Path $rumBak)) { Copy-Item $live $rumBak }

Copy-Item $srcBak $live -Force

if ($State -eq 'vanilla') {
    if (Test-Path $pack) { Move-Item $pack $packOff -Force }
} else {
    if (Test-Path $packOff) { Move-Item $packOff $pack -Force }
}

Write-Host ""
Write-Host ("now installed: {0}" -f (Describe (Short-Hash $live))) -ForegroundColor Green
Write-Host ("rum pack     : {0}" -f $(if (Test-Path $pack) { 'INSTALLED' } else { 'disabled' })) -ForegroundColor Green
Write-Host ""
Write-Host "Reminder: startpos edits are not save-compatible - start a NEW campaign."


