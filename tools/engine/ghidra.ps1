<#
  ghidra.ps1 - run GhidraToolkit.java headless against the analysed EmpireTW
  project, so decompilation can be asked for from here instead of by hand.

  The project is already analysed (GhidraProjects\EmpireTW.rep), so -process
  with -noanalysis reuses it and a query takes seconds rather than re-analysing
  a 20MB binary.

  Modes (from GhidraToolkit.java): decompile, callers, disasm, xrefs,
  constants, vtable. args[1] is always the output file.

  Usage
    .\ghidra.ps1 decompile out.txt 0x005F2126
    .\ghidra.ps1 disasm    out.txt 0x005F2126 120
    .\ghidra.ps1 xrefs     out.txt 0x01223ED8
    .\ghidra.ps1 callers   out.txt 0x00441E10 2 50
#>
param(
    [Parameter(Mandatory=$true, Position=0)][string]$Mode,
    [Parameter(Mandatory=$true, Position=1)][string]$Out,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest,
    [string]$Root,
    [switch]$Quiet
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $Root) { $Root = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'Total war empire tools') }
$ErrorActionPreference = 'Stop'

$headless = Join-Path $Root "ghidra_12.1.3_PUBLIC\support\analyzeHeadless.bat"
if (-not (Test-Path $headless)) { throw "no analyzeHeadless at $headless" }
$projDir  = Join-Path $Root "GhidraProjects"
$scripts  = Join-Path $projDir "scripts"
$outFull  = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $projDir $Out }
$log      = "$outFull.run.log"

$a = @($projDir, "EmpireTW", "-process", "Empire.exe", "-noanalysis",
       "-scriptPath", $scripts, "-postScript", "GhidraToolkit.java", $Mode, $outFull) + $Rest

& $headless @a *> $log
if (-not (Test-Path $outFull)) {
    Write-Host "no output produced - tail of $log :" -ForegroundColor Yellow
    Get-Content $log -Tail 20
    return
}
"{0}  ({1:N0} bytes)" -f $outFull, (Get-Item $outFull).Length
if (-not $Quiet) { Get-Content $outFull }
