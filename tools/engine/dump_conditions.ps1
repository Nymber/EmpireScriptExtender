<#
  dump_conditions.ps1 - recover the FULL signature of every scripting
  condition from Empire.exe, without calling any of them.

  WHY THIS EXISTS
    Calling a condition with the wrong argument shape does not raise a Lua
    error - it reaches native code that dereferences null and kills the
    process. A live "just try it and see" probe cost one campaign turn and a
    crash. Everything needed is static: each condition is registered by a
    fixed code sequence

        push <native function>
        push <param doc 1>            (one per parameter, may be absent)
        push <usage example>
        push <description>
        push <param doc / "none">
        push <name>
        mov  ecx, <registry object>
        call 00D1F870

    so walking back from every call site and resolving the pushed pointers
    yields name, usage, description, per-parameter documentation and the
    implementing function address.

  The parameter docs are the prize: the help text for
  RegionSlotBuildingTypeExists says "of the specified type", which reads as a
  building TYPE, but its parameter doc says "The key of the building level you
  are querying from the building_levels table". The two disagree and the
  parameter doc is the one that matches the code.

  Usage
    .\dump_conditions.ps1                      # everything
    .\dump_conditions.ps1 -Match "Building"    # filter on any field
    .\dump_conditions.ps1 -Match "Region" -Csv out.csv
#>
param(
    [string]$Exe,
    [string]$Match = "",
    [string]$Csv   = "",
    [uint32]$Registrar = 0x00D1F870,
    # Find every registrar instead of dumping one. Conditions and effects use
    # DIFFERENT ones (00D1F870 and 00D1FB60), so assuming a single table hides
    # whole categories of the scripting API.
    [switch]$Discover
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $Exe) { $Exe = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'Empire.exe') }

$b  = [System.IO.File]::ReadAllBytes($Exe)
$pe = [BitConverter]::ToInt32($b, 0x3C)
$ns = [BitConverter]::ToUInt16($b, $pe + 6)
$os = [BitConverter]::ToUInt16($b, $pe + 20)
$sc = $pe + 24 + $os
$secs = @()
for ($i = 0; $i -lt $ns; $i++) {
    $o = $sc + $i * 40
    $secs += [pscustomobject]@{
        Name = [Text.Encoding]::ASCII.GetString($b, $o, 8).Trim([char]0)
        VA   = 0x400000 + [BitConverter]::ToUInt32($b, $o + 12)
        FO   = [BitConverter]::ToUInt32($b, $o + 20)
        Len  = [BitConverter]::ToUInt32($b, $o + 16)
    }
}
$text = $secs | Where-Object { $_.Name -eq ".text" } | Select-Object -First 1
if (-not $text) { throw "no .text section" }
function VA2FO([uint32]$va) {
    foreach ($s in $secs) { if ($va -ge $s.VA -and $va -lt ($s.VA + $s.Len)) { return [int]($s.FO + ($va - $s.VA)) } }
    return -1
}
function StrAt([uint32]$va) {
    $fo = VA2FO $va
    if ($fo -lt 0) { return $null }
    $sb = New-Object Text.StringBuilder
    for ($i = $fo; $i -lt $fo + 200; $i++) {
        $c = $b[$i]
        if ($c -eq 0) { break }
        if ($c -lt 32 -or $c -ge 127) { return $null }
        [void]$sb.Append([char]$c)
    }
    if ($sb.Length -lt 2) { return $null }
    return $sb.ToString()
}

# Every `call rel32` whose target is the registrar.
$rows = @()
$tEnd = $text.FO + $text.Len
for ($fo = $text.FO; $fo -lt $tEnd - 5; $fo++) {
    if ($b[$fo] -ne 0xE8) { continue }
    $va  = $text.VA + ($fo - $text.FO)
    # Mask to 32 bits: a backwards branch makes va+5+rel negative as a signed
    # 64-bit value, and casting that straight to uint32 throws rather than
    # wrapping the way the CPU does.
    # NOTE the L: PowerShell reads 0xFFFFFFFF as Int32 -1, so masking with the
    # bare literal is `-band -1`, a no-op that leaves the value negative and
    # the cast still throwing.
    $tgt = [uint32](([int64]$va + 5 + [BitConverter]::ToInt32($b, $fo + 1)) -band 0xFFFFFFFFL)
    if (-not $Discover -and $tgt -ne $Registrar) { continue }

    # Walk BACK over the contiguous run of `push imm32` (68 xx xx xx xx),
    # allowing the `mov ecx, imm32` (B9) that always precedes the call.
    $p = $fo
    if ($p - 5 -ge $text.FO -and $b[$p - 5] -eq 0xB9) { $p -= 5 }
    $pushes = @()
    while ($p - 5 -ge $text.FO -and $b[$p - 5] -eq 0x68) {
        $p -= 5
        $pushes = ,([BitConverter]::ToUInt32($b, $p + 1)) + $pushes
    }
    if ($pushes.Count -lt 3) { continue }

    # Last push is the condition name; first is the implementing function.
    $name = StrAt $pushes[-1]
    if (-not $name -or $name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
    $fn   = $pushes[0]
    $docs = @()
    for ($k = 1; $k -lt $pushes.Count - 1; $k++) {
        $s = StrAt $pushes[$k]
        if ($s) { $docs += $s }
    }
    $usage = ($docs | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*\(' } | Select-Object -First 1)
    $rest  = $docs | Where-Object { $_ -ne $usage }
    $rows += [pscustomobject]@{
        Name      = $name
        Usage     = $usage
        Func      = ("{0:X8}" -f $fn)
        Registrar = ("{0:X8}" -f $tgt)
        Details   = ($rest -join "  ||  ")
    }
}

if ($Discover) {
    "registrars found (each is a separate scripting namespace):"
    $rows | Group-Object Registrar | Sort-Object Count -Descending | ForEach-Object {
        "  {0}  {1,4} entr{2}   e.g. {3}" -f $_.Name, $_.Count,
            $(if ($_.Count -eq 1) { "y " } else { "ies" }),
            (($_.Group | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ", ")
    }
    if ($Csv) { $rows | Sort-Object Registrar, Name | Export-Csv -NoTypeInformation -Encoding UTF8 $Csv; "`nwritten $Csv" }
    return
}

$rows = $rows | Sort-Object Name -Unique
if ($Match) { $rows = $rows | Where-Object { "$($_.Name) $($_.Usage) $($_.Details)" -match $Match } }
"{0} condition registration(s)" -f $rows.Count
""
foreach ($r in $rows) {
    "{0}  {1}" -f $r.Func, $r.Name
    if ($r.Usage)   { "    usage : {0}" -f $r.Usage }
    if ($r.Details) { "    doc   : {0}" -f $r.Details }
}
if ($Csv) { $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $Csv; "`nwritten $Csv" }
