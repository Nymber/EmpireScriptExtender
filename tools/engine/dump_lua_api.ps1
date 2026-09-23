<#
  dump_lua_api.ps1 - recover a THIRD-SHAPE Lua registration table from
  Empire.exe: the one at 0058BD60 that carries the battle/UI commands,
  including the camera.

  WHY A SECOND TOOL
    dump_conditions.ps1 handles the campaign registrars, whose call sites end
    with the NAME pushed last:
        push func, push author, push usage, push desc, push doc, push name
        mov ecx, <registry> ; call 00D1F870   (conditions)
                            ; call 00D1FB60   (effects)
                            ; call 00D210A0   (events)

    This table is a different shape entirely - three pushes, name in the
    MIDDLE:
        push <description>
        push <name>
        push <function>
        mov ecx, <thunk/context> ; call 0058BD60

    Feeding it to the other parser yields the function pointer as a "name" and
    silent nonsense, so the shape is handled explicitly rather than guessed.

  Usage
    .\dump_lua_api.ps1                       # everything at 0058BD60
    .\dump_lua_api.ps1 -Match "camera|Camera"
    .\dump_lua_api.ps1 -Registrar 0x0058BD60 -Csv out.csv
#>
param(
    [string]$Exe,
    [string]$Match = "",
    [string]$Csv   = "",
    [uint32]$Registrar = 0x0058BD60
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
function VA2FO([uint32]$va) {
    foreach ($s in $secs) { if ($va -ge $s.VA -and $va -lt ($s.VA + $s.Len)) { return [int]($s.FO + ($va - $s.VA)) } }
    return -1
}
function StrAt([uint32]$va) {
    $fo = VA2FO $va
    if ($fo -lt 0) { return $null }
    $sb = New-Object Text.StringBuilder
    for ($i = $fo; $i -lt $fo + 300; $i++) {
        $c = $b[$i]
        if ($c -eq 0) { break }
        if ($c -lt 32 -or $c -ge 127) { return $null }
        [void]$sb.Append([char]$c)
    }
    if ($sb.Length -lt 2) { return $null }
    return $sb.ToString()
}

$rows = @()
$tEnd = $text.FO + $text.Len
for ($fo = $text.FO; $fo -lt $tEnd - 5; $fo++) {
    if ($b[$fo] -ne 0xE8) { continue }
    $va  = $text.VA + ($fo - $text.FO)
    # mask to 32 bits: a backwards branch is negative as Int64 and the cast throws
    $tgt = [uint32](([int64]$va + 5 + [BitConverter]::ToInt32($b, $fo + 1)) -band 0xFFFFFFFFL)
    if ($tgt -ne $Registrar) { continue }

    $p = $fo
    if ($p - 5 -ge $text.FO -and $b[$p - 5] -eq 0xB9) { $p -= 5 }   # mov ecx, imm32
    $pushes = @()
    while ($p - 5 -ge $text.FO -and $b[$p - 5] -eq 0x68) {
        $p -= 5
        $pushes = ,([BitConverter]::ToUInt32($b, $p + 1)) + $pushes
    }
    if ($pushes.Count -lt 3) { continue }

    # shape: [..., description, name, function]
    $fn   = $pushes[-1]
    $name = StrAt $pushes[-2]
    $desc = StrAt $pushes[-3]
    if (-not $name -or $name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
    $rows += [pscustomobject]@{
        Name = $name
        Func = ("{0:X8}" -f $fn)
        Desc = $desc
    }
}

$rows = $rows | Sort-Object Name -Unique
if ($Match) { $rows = $rows | Where-Object { "$($_.Name) $($_.Desc)" -match $Match } }
"{0} registration(s) at {1:X8}" -f $rows.Count, $Registrar
""
foreach ($r in $rows) {
    "{0}  {1}" -f $r.Func, $r.Name
    if ($r.Desc) { "    {0}" -f $r.Desc }
}
if ($Csv) { $rows | Export-Csv -NoTypeInformation -Encoding UTF8 $Csv; "`nwritten $Csv" }
