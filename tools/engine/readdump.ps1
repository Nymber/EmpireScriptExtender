# Minimal minidump reader: exception record + x86 thread context + memory peek.
param([string]$Dump, [string]$ExeBase)

$b = [System.IO.File]::ReadAllBytes($Dump)
if ([System.Text.Encoding]::ASCII.GetString($b,0,4) -ne 'MDMP') { throw "not a minidump" }
$nStreams = [BitConverter]::ToUInt32($b,8)
$dirRva   = [BitConverter]::ToUInt32($b,12)

$streams = @{}
for ($i=0; $i -lt $nStreams; $i++) {
    $o = $dirRva + $i*12
    $streams[[int][BitConverter]::ToUInt32($b,$o)] = @{ Size=[BitConverter]::ToUInt32($b,$o+4); Rva=[BitConverter]::ToUInt32($b,$o+8) }
}
Write-Host ("streams: " + (($streams.Keys | Sort-Object) -join ', '))

# --- ExceptionStream (6) ---
$ex = $streams[6]
if (-not $ex) { throw "no exception stream" }
$e = $ex.Rva
$tid  = [BitConverter]::ToUInt32($b,$e)
$code = [BitConverter]::ToUInt32($b,$e+8)
$addr = [BitConverter]::ToUInt64($b,$e+24)
$nparm= [BitConverter]::ToUInt32($b,$e+32)
$ctxRva = [BitConverter]::ToUInt32($b,$e+8+152+4)
Write-Host ("`nEXCEPTION  code=0x{0:X8}  address=0x{1:X}  thread={2}  params={3}" -f $code,$addr,$tid,$nparm)

# --- x86 CONTEXT ---
$c = $ctxRva
$reg = [ordered]@{
  Edi=[BitConverter]::ToUInt32($b,$c+156); Esi=[BitConverter]::ToUInt32($b,$c+160)
  Ebx=[BitConverter]::ToUInt32($b,$c+164); Edx=[BitConverter]::ToUInt32($b,$c+168)
  Ecx=[BitConverter]::ToUInt32($b,$c+172); Eax=[BitConverter]::ToUInt32($b,$c+176)
  Ebp=[BitConverter]::ToUInt32($b,$c+180); Eip=[BitConverter]::ToUInt32($b,$c+184)
  Esp=[BitConverter]::ToUInt32($b,$c+196)
}
Write-Host "`nREGISTERS"
foreach ($k in $reg.Keys) { Write-Host ("  {0} = 0x{1:X8}  ({2})" -f $k,$reg[$k],$reg[$k]) }

# --- memory ranges (Memory64List = 9, MemoryList = 5) ---
$script:ranges = @()
if ($streams[9]) {
    $m = $streams[9].Rva
    $n = [BitConverter]::ToUInt64($b,$m)
    $base = [BitConverter]::ToUInt64($b,$m+8)
    $off = $base
    for ($i=0; $i -lt [int]$n; $i++) {
        $o = $m + 16 + $i*16
        $sa = [BitConverter]::ToUInt64($b,$o); $sz = [BitConverter]::ToUInt64($b,$o+8)
        $script:ranges += ,@($sa,$sz,$off); $off += $sz
    }
}
if ($streams[5]) {
    $m = $streams[5].Rva
    $n = [BitConverter]::ToUInt32($b,$m)
    for ($i=0; $i -lt [int]$n; $i++) {
        $o = $m + 4 + $i*16
        $sa = [BitConverter]::ToUInt64($b,$o)
        $sz = [BitConverter]::ToUInt32($b,$o+8); $rv = [BitConverter]::ToUInt32($b,$o+12)
        $script:ranges += ,@($sa,[uint64]$sz,[uint64]$rv)
    }
}
Write-Host ("`nmemory ranges: {0}" -f $script:ranges.Count)

function Peek([uint64]$va,[int]$count) {
    foreach ($r in $script:ranges) {
        if ($va -ge $r[0] -and ($va + $count) -le ($r[0]+$r[1])) {
            $fo = [int]($r[2] + ($va - $r[0]))
            return $b[$fo..($fo+$count-1)]
        }
    }
    return $null
}
function PeekU32([uint64]$va) { $d = Peek $va 4; if ($d) { return [BitConverter]::ToUInt32($d,0) } return $null }

# Static VA of the faulting instruction. Empire.exe is ASLR'd, so the live EIP
# is NOT the address to look up in Ghidra or in a disk disassembly: subtract the
# live base. WER's "Fault offset" is already module-relative, so
#   static VA = 0x400000 + fault offset  =  Eip - liveBase + 0x400000.
if ($ExeBase) {
    $lb = [uint64]("0x" + ($ExeBase -replace '^0x',''))
    Write-Host ("`nSTATIC VA (for Ghidra / disk disassembly) = 0x{0:X8}" -f
                ([uint64]$reg.Eip - $lb + 0x400000))
} else {
    Write-Host "`nPass -ExeBase <live base> to convert Eip to a static VA."
    Write-Host ("  live base = Eip - (WER fault offset).  Eip = 0x{0:X8}" -f $reg.Eip)
}

# Generic: show what each register points at, when the dump captured it. A
# minidump keeps the stack and some heap, so expect misses - the registers
# themselves are usually the diagnosis (a loop counter that disagrees with a
# table size is the tell).
Write-Host "`n--- what the registers point at (4 dwords each, where captured) ---"
foreach ($k in 'Eax','Ebx','Ecx','Edx','Esi','Edi') {
    $va = [uint64]$reg[$k]
    if ($va -lt 0x10000) { Write-Host ("  {0} = {1,-12} (small - a count or index, not a pointer)" -f $k,$reg[$k]); continue }
    $d = Peek $va 16
    if ($d) {
        $w = @(); for ($j=0; $j -lt 4; $j++) { $w += ("{0:X8}" -f [BitConverter]::ToUInt32($d,$j*4)) }
        Write-Host ("  {0} = 0x{1:X8} -> {2}" -f $k,$va,($w -join ' '))
    } else {
        Write-Host ("  {0} = 0x{1:X8}    (not captured in dump)" -f $k,$va)
    }
}

Write-Host "`n--- stack (esp, 32 dwords) ---"
$sd = Peek ([uint64]$reg.Esp) 128
if ($sd) {
    for ($i=0; $i -lt 32; $i+=4) {
        $line = ""
        for ($j=0; $j -lt 4; $j++) { $line += ("{0:X8} " -f [BitConverter]::ToUInt32($sd,($i+$j)*4)) }
        Write-Host ("  +{0:X2}  {1}" -f ($i*4), $line)
    }
}
