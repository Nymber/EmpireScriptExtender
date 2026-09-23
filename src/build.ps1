<#
  build.ps1 - build ese_proxy.c into a 32-bit dinput8.dll.

  Empire is 32-bit, so the DLL must be 32-bit (i386). There is no C toolchain on
  this machine yet; this script finds whichever of the supported ones you
  install and uses it. Zig is recommended: a single portable zip, no installer,
  no admin rights, and it cross-compiles to 32-bit Windows out of the box.

    Zig         https://ziglang.org/download/   (unzip, add to PATH)
    w64devkit   https://github.com/skeeto/w64devkit/releases  (portable MinGW)
    MSVC        Visual Studio Build Tools, "C++ build tools" workload

  Usage:
    .\build.ps1              # build to .\dinput8.dll
    .\build.ps1 -Deploy      # build, then install into the game folder
                             # (renames the game's existing dinput8.dll if any)
#>
param([switch]$Deploy)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $gameDir) { $gameDir = (& (Join-Path $PSScriptRoot '..\empire_paths.ps1') -Quiet) }

$ErrorActionPreference = "Stop"
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$src     = Join-Path $here "ese_proxy.c"
$out     = Join-Path $here "dinput8.dll"
$gameDir

if (-not (Test-Path $src)) { throw "missing source: $src" }

function Have($name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Prefer a zig unpacked into the tools folder, so nothing depends on PATH.
$zigLocal = $null
$toolsDir = Split-Path -Parent (Split-Path -Parent $here)
$cand = Get-ChildItem $toolsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "zig-*windows*" } |
        Sort-Object Name -Descending | Select-Object -First 1
if ($cand) {
    $p = Join-Path $cand.FullName "zig.exe"
    if (Test-Path $p) { $zigLocal = $p }
}
if (-not $zigLocal -and (Have "zig")) { $zigLocal = (Get-Command zig).Source }

if ($zigLocal) {
    Write-Host "building with zig: $zigLocal"
    # -target x86-windows-gnu : 32-bit, MinGW ABI - what a proxy DLL for a
    #                           32-bit game needs. Empire is i386.
    # -Wl,--kill-at : strip the stdcall @N decoration from export names. WITHOUT
    #   this the DLL exports "DirectInput8Create@20" while Empire imports
    #   "DirectInput8Create", the import cannot be resolved, and the game
    #   refuses to start. Non-negotiable for a proxy DLL.
    #
    # Compiler warnings arrive on stderr, and PowerShell 5.1 turns native stderr
    # into error records that $ErrorActionPreference='Stop' then makes fatal -
    # which reported "build failed" on a build that actually succeeded. Judge
    # success by the exit code only.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # ese.def aliases the undecorated export names (see that file for why).
    # Zig's lld rejects --kill-at, so the .def is how we get "DirectInput8Create"
    # instead of "DirectInput8Create@20".
    $def = Join-Path $here "ese.def"
    & $zigLocal cc -target x86-windows-gnu -shared -O2 `
        -o $out $src $def -lkernel32 -luser32 2>&1 | ForEach-Object { Write-Host "  $_" }
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($rc -ne 0) { throw "zig build failed (exit $rc)" }
}
elseif (Have "i686-w64-mingw32-gcc") {
    Write-Host "building with mingw (i686)..."
    & i686-w64-mingw32-gcc -shared -O2 -o $out $src -lkernel32 -luser32
    if ($LASTEXITCODE -ne 0) { throw "mingw build failed" }
}
elseif (Have "gcc") {
    Write-Host "building with gcc -m32 (must be a 32-bit-capable toolchain)..."
    & gcc -m32 -shared -O2 -o $out $src -lkernel32 -luser32
    if ($LASTEXITCODE -ne 0) { throw "gcc build failed (is it 32-bit capable?)" }
}
elseif (Have "cl") {
    Write-Host "building with MSVC cl (run from an x86 Native Tools prompt)..."
    Push-Location $here
    & cl /nologo /LD /O2 ese_proxy.c /link /OUT:dinput8.dll kernel32.lib user32.lib
    $rc = $LASTEXITCODE; Pop-Location
    if ($rc -ne 0) { throw "cl build failed" }
}
else {
    Write-Host ""
    Write-Host "No C compiler found. Install ONE of these (no admin needed for the first two):"
    Write-Host "  Zig        https://ziglang.org/download/   <- recommended, single portable zip"
    Write-Host "  w64devkit  https://github.com/skeeto/w64devkit/releases"
    Write-Host "  MSVC       Visual Studio Build Tools (C++ workload)"
    Write-Host ""
    Write-Host "Then re-run this script."
    exit 1
}

$fi = Get-Item $out
Write-Host ("built {0} ({1:N0} bytes)" -f $fi.Name, $fi.Length)

# Sanity-check it really is a 32-bit PE - a 64-bit DLL will silently fail to load.
$fs = [System.IO.File]::OpenRead($out)
$br = New-Object System.IO.BinaryReader($fs)
$fs.Position = 0x3C; $peOff = $br.ReadInt32()
$fs.Position = $peOff + 4; $machine = $br.ReadUInt16()
$br.Close()
if ($machine -eq 0x014C) { Write-Host "  machine: 0x014C (i386) - correct for Empire" }
else { Write-Host ("  WARNING: machine=0x{0:X4}, expected 0x014C (i386). Empire will NOT load this." -f $machine) }

# Verify export NAMES are undecorated. A proxy whose exports carry the stdcall
# @N suffix cannot satisfy Empire's imports, and the symptom is the game simply
# refusing to launch - so check it here rather than discovering it that way.
$bytes = [System.IO.File]::ReadAllBytes($out)
$po = [BitConverter]::ToInt32($bytes,0x3C)
$ns = [BitConverter]::ToUInt16($bytes,$po+6); $os = [BitConverter]::ToUInt16($bytes,$po+20)
$st = $po+24+$os; $secs = @()
for ($i=0; $i -lt $ns; $i++) { $o=$st+$i*40
  $secs += [pscustomobject]@{VA=[BitConverter]::ToUInt32($bytes,$o+12);VS=[BitConverter]::ToUInt32($bytes,$o+8);RP=[BitConverter]::ToUInt32($bytes,$o+20)} }
function Rva2Off($r){ foreach($s in $secs){ if($r -ge $s.VA -and $r -lt ($s.VA+$s.VS)){ return $s.RP+($r-$s.VA) } } return -1 }
$expRva = [BitConverter]::ToUInt32($bytes,$po+24+0x60)
$names = @()
if ($expRva -ne 0) {
    $e = Rva2Off $expRva
    $cnt = [BitConverter]::ToUInt32($bytes,$e+24)
    $nOff = Rva2Off ([BitConverter]::ToUInt32($bytes,$e+32))
    for ($i=0; $i -lt $cnt; $i++) {
        $so = Rva2Off ([BitConverter]::ToUInt32($bytes,$nOff+$i*4))
        $end = $so; while ($bytes[$end] -ne 0) { $end++ }
        $names += [System.Text.Encoding]::ASCII.GetString($bytes,$so,$end-$so)
    }
}
Write-Host ("  exports: {0}" -f ($names -join ", "))
# What actually matters is that the UNDECORATED names exist - Windows resolves
# imports by exact name. Extra "Name@N" aliases alongside them are harmless, so
# they are worth a note but not a failure.
$required = @('DirectInput8Create','DllGetClassObject','DllCanUnloadNow',
              'DllRegisterServer','DllUnregisterServer')
$missing = $required | Where-Object { $names -notcontains $_ }
if ($missing) {
    Write-Host ("  ERROR: missing undecorated export(s): {0}" -f ($missing -join ", "))
    Write-Host "         Empire imports the undecorated names; it would refuse to launch."
    Write-Host "         Check ese.def is being passed to the linker."
    throw "missing required exports - refusing to deploy"
}
if ($names -match '@') {
    Write-Host "  note: decorated @N aliases also present (harmless - the undecorated names resolve)"
}
Write-Host "  all 5 undecorated exports present - proxy will satisfy Empire's import"

if ($Deploy) {
    if (Get-Process Empire -ErrorAction SilentlyContinue) { throw "Empire is running - close it first" }
    $dest = Join-Path $gameDir "dinput8.dll"
    if (Test-Path $dest) {
        # Only back up a REAL dinput8 - never a previous copy of OURS. The first
        # version of this check merely tested whether a backup existed, so the
        # second deploy happily saved our own proxy as "the original".
        # Our builds embed the ESE version string; use it as the marker.
        $destBytes = [System.IO.File]::ReadAllBytes($dest)
        $marker = [System.Text.Encoding]::ASCII.GetBytes("ESE proxy")
        $isOurs = $false
        for ($i = 0; $i -le ($destBytes.Length - $marker.Length); $i++) {
            if ($destBytes[$i] -eq $marker[0]) {
                $m = $true
                for ($j = 1; $j -lt $marker.Length; $j++) { if ($destBytes[$i+$j] -ne $marker[$j]) { $m = $false; break } }
                if ($m) { $isOurs = $true; break }
            }
        }
        if ($isOurs) {
            Write-Host "existing dinput8.dll is a previous ESE build - not backing it up"
        } else {
            $bak = Join-Path $gameDir "dinput8_original.dll"
            if (-not (Test-Path $bak)) {
                Copy-Item $dest $bak
                Write-Host "backed up the REAL dinput8.dll -> dinput8_original.dll"
            }
        }
    }
    Copy-Item $out $dest -Force
    Write-Host "deployed -> $dest"
    Write-Host "Launch the game; check ese_log.txt in the game folder."
}
