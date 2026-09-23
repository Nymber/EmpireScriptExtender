<#
  scanmem.ps1 - a scanner for Empire.exe.

  THE WORKFLOW - the value must CHANGE; that is what makes it converge
    .\scanmem.ps1 -First -Int 15     # every aligned dword equal to 15
    (fire a volley so ammo drops)
    .\scanmem.ps1 -Next  -Int 14     # keep only those that became 14
    (repeat until a handful remain)

    .\scanmem.ps1 -Read 0x1234ABCD             # watch one address
    .\scanmem.ps1 -Dump 0x1234ABCD -Len 256    # the struct around it
    .\scanmem.ps1 -Watch 0x1234ABCD -Seconds 20  # poll it while you play

  Candidates persist in scanmem_state.bin between runs (raw int64s - a text
  file with millions of lines is itself the bottleneck), so each step is its
  own command and you can play the game in between.

  SPEED: the search and the refine both run in compiled C#. A PowerShell byte
  loop over the same 1,566 regions took 190 SECONDS per pass, which makes
  iterative scanning unusable; this is a couple of seconds.
#>
param(
    [switch]$First,
    [switch]$Snapshot,
    [switch]$Diff,
    [int]$Delta = 1,
    [string]$Snap = "$PSScriptRoot\scanmem_snap.bin",
    [switch]$Next,
    [int]$Int,
    [single]$Float,
    [string]$Read,
    [string]$Dump,
    [string]$Watch,
    [int]$Seconds = 15,
    [int]$Len = 128,
    [ValidateSet(1,2,4)][int]$Width = 4,
    [string]$State = "$PSScriptRoot\scanmem_state.bin",
    [switch]$IncludeImage
)

$ErrorActionPreference = 'Stop'

if (-not ("EmpScan" -as [type])) {
Add-Type @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public class EmpScan {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
  [DllImport("kernel32.dll")]
  static extern int VirtualQueryEx(IntPtr h, IntPtr addr, out MBI mbi, int len);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  [StructLayout(LayoutKind.Sequential)]
  public struct MBI {
    public IntPtr BaseAddress; public IntPtr AllocationBase; public int AllocationProtect;
    public IntPtr RegionSize; public int State; public int Protect; public int Type;
  }

  IntPtr h;
  public EmpScan(int pid) {
    h = OpenProcess(0x0010 | 0x0400, false, pid);
    if (h == IntPtr.Zero) throw new Exception("OpenProcess failed (" + Marshal.GetLastWin32Error() + ")");
  }
  public void Close() { if (h != IntPtr.Zero) { CloseHandle(h); h = IntPtr.Zero; } }

  public List<long[]> Regions(bool includeImage) {
    var outp = new List<long[]>();
    long addr = 0;
    MBI mbi;
    while (addr < 0x7FFF0000L) {
      if (VirtualQueryEx(h, (IntPtr)addr, out mbi, Marshal.SizeOf(typeof(MBI))) == 0) break;
      long size = (long)mbi.RegionSize;
      if (size <= 0) break;
      bool readable = mbi.Protect == 0x02 || mbi.Protect == 0x04 || mbi.Protect == 0x20 || mbi.Protect == 0x40;
      bool isImage  = mbi.Type == 0x1000000;
      if (mbi.State == 0x1000 && readable && (includeImage || !isImage) && size <= 64L*1024*1024)
        outp.Add(new long[] { (long)mbi.BaseAddress, size });
      addr += size;
    }
    return outp;
  }

  public byte[] ReadBlock(long addr, int size) {
    var buf = new byte[size];
    IntPtr got;
    if (!ReadProcessMemory(h, (IntPtr)addr, buf, size, out got)) return null;
    if ((long)got < size) return null;
    return buf;
  }

  // Every value equal to `val` at the given WIDTH (1, 2 or 4 bytes).
  // Width matters: a per-soldier ammo counter is very plausibly a byte, and a
  // 4-byte aligned scan cannot see it at all - a dword scan for 15 found only
  // 7 survivors where ~160 soldiers should have decremented.
  // Widths 1 and 2 are scanned at EVERY offset, not just aligned ones.
  public long Scan(int val, int width, bool includeImage, string statePath) {
    var pat = BitConverter.GetBytes(val);
    int step = (width == 4) ? 4 : 1;
    long n = 0;
    using (var fs = new FileStream(statePath, FileMode.Create, FileAccess.Write))
    using (var bw = new BinaryWriter(fs)) {
      foreach (var r in Regions(includeImage)) {
        var buf = ReadBlock(r[0], (int)r[1]);
        if (buf == null) continue;
        int lim = buf.Length - width;
        for (int i = 0; i <= lim; i += step) {
          bool hit = true;
          for (int k = 0; k < width; k++) if (buf[i+k] != pat[k]) { hit = false; break; }
          if (!hit) continue;
          bw.Write(r[0] + i); n++;
        }
      }
    }
    return n;
  }

  // Keep only saved candidates that NOW hold `val`. Reads each region once
  // rather than one ReadProcessMemory per candidate.
  public long Refine(int val, int width, string statePath) {
    var pat = BitConverter.GetBytes(val);
    var cands = new List<long>();
    using (var fs = new FileStream(statePath, FileMode.Open, FileAccess.Read))
    using (var br = new BinaryReader(fs))
      while (fs.Position < fs.Length) cands.Add(br.ReadInt64());
    cands.Sort();

    var keep = new List<long>();
    int idx = 0;
    foreach (var r in Regions(true)) {
      long lo = r[0], hi = r[0] + r[1];
      while (idx < cands.Count && cands[idx] < lo) idx++;
      if (idx >= cands.Count) break;
      if (cands[idx] >= hi) continue;
      var buf = ReadBlock(lo, (int)r[1]);
      if (buf == null) { while (idx < cands.Count && cands[idx] < hi) idx++; continue; }
      while (idx < cands.Count && cands[idx] < hi) {
        int off = (int)(cands[idx] - lo);
        if (off >= 0 && off + width <= buf.Length) {
          bool hit = true;
          for (int k = 0; k < width; k++) if (buf[off+k] != pat[k]) { hit = false; break; }
          if (hit) keep.Add(cands[idx]);
        }
        idx++;
      }
    }
    using (var fs = new FileStream(statePath, FileMode.Create, FileAccess.Write))
    using (var bw = new BinaryWriter(fs))
      foreach (var a in keep) bw.Write(a);
    return keep.Count;
  }

  // ---- unknown-initial-value scanning ------------------------------------
  // Snapshot every candidate region to disk, then after the game state moves,
  // find every byte that changed by an exact delta. This needs NO knowledge of
  // the starting value, which matters when the number on screen cannot be
  // trusted to be the thing actually stored.
  // Format per region: [long base][int size][size bytes].
  public long Snapshot(bool includeImage, string path) {
    long total = 0;
    using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
    using (var bw = new BinaryWriter(fs)) {
      foreach (var r in Regions(includeImage)) {
        var buf = ReadBlock(r[0], (int)r[1]);
        if (buf == null) continue;
        bw.Write(r[0]); bw.Write(buf.Length); bw.Write(buf);
        total += buf.Length;
      }
    }
    return total;
  }

  // delta = old - new. 1 means "went down by exactly one".
  // Returns addresses, and also writes them as the new candidate set.
  public long Diff(string snapPath, int delta, string statePath, out long regions) {
    long n = 0; regions = 0;
    using (var fs = new FileStream(snapPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
    using (var br = new BinaryReader(fs))
    using (var os = new FileStream(statePath, FileMode.Create, FileAccess.Write))
    using (var ow = new BinaryWriter(os)) {
      while (fs.Position < fs.Length) {
        long base_ = br.ReadInt64();
        int size = br.ReadInt32();
        var old = br.ReadBytes(size);
        regions++;
        var now = ReadBlock(base_, size);
        if (now == null) continue;
        for (int i = 0; i < size; i++) {
          if (old[i] - now[i] != delta) continue;
          ow.Write(base_ + i); n++;
        }
      }
    }
    return n;
  }

  public static long[] Load(string statePath) {
    var l = new List<long>();
    using (var fs = new FileStream(statePath, FileMode.Open, FileAccess.Read))
    using (var br = new BinaryReader(fs))
      while (fs.Position < fs.Length) l.Add(br.ReadInt64());
    return l.ToArray();
  }
}
"@
}

$proc = Get-Process Empire -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw "Empire.exe is not running" }
$scan = New-Object EmpScan $proc.Id

function Parse-Addr([string]$v) { [int64]("0x" + ($v -replace '^0x','')) }

try {
    if ($Read)  {
        $a = Parse-Addr $Read
        $b = $scan.ReadBlock($a, 4)
        if ($null -eq $b) { "could not read 0x{0:X}" -f $a }
        else { "0x{0:X}  int={1}  float={2}" -f $a, [BitConverter]::ToInt32($b,0), [BitConverter]::ToSingle($b,0) }
        return
    }
    if ($Watch) {
        $a = Parse-Addr $Watch
        "watching 0x{0:X} for {1}s - play the game" -f $a, $Seconds
        $last = $null; $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            $b = $scan.ReadBlock($a, 4)
            if ($null -ne $b) {
                $v = [BitConverter]::ToInt32($b,0)
                if ($v -ne $last) { "{0:HH:mm:ss}  int={1}  float={2}" -f (Get-Date), $v, [BitConverter]::ToSingle($b,0); $last = $v }
            }
            Start-Sleep -Milliseconds 250
        }
        return
    }
    if ($Dump) {
        $a = Parse-Addr $Dump
        $b = $scan.ReadBlock($a, $Len)
        if ($null -eq $b) { "could not read 0x{0:X}" -f $a; return }
        for ($i = 0; $i -lt $Len; $i += 16) {
            $hex = ($b[$i..([Math]::Min($i+15,$Len-1))] | ForEach-Object { $_.ToString('x2') }) -join ' '
            $ints = @(); for ($j = 0; $j -lt 16; $j += 4) { if ($i+$j+4 -le $Len) { $ints += ("{0,10}" -f [BitConverter]::ToInt32($b,$i+$j)) } }
            "+{0:X3}  {1,-48} {2}" -f $i, $hex, ($ints -join '')
        }
        return
    }

    # A float is scanned by reinterpreting its 4 bytes as an int, so one code
    # path covers both. This matters here: the battle-script layer pushes
    # AmmoRemaining with `movss`, so the live counter is quite possibly a
    # float even though unit_stats_land.ammo is an int.
    if ($Snapshot) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $n = $scan.Snapshot($IncludeImage.IsPresent, $Snap)
        "snapshot: {0:N0} MB in {1:N1}s -> {2}" -f ($n/1MB), $sw.Elapsed.TotalSeconds, $Snap
        "now change the value in game, then:  .\scanmem.ps1 -Diff -Delta 1"
        return
    }
    if ($Diff) {
        if (-not (Test-Path $Snap)) { throw "no snapshot at $Snap - run -Snapshot first" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $regions = [int64]0
        $n = $scan.Diff($Snap, $Delta, $State, [ref]$regions)
        "{0:N0} byte(s) changed by exactly {1} across {2:N0} region(s)  ({3:N1}s)" -f $n, $Delta, $regions, $sw.Elapsed.TotalSeconds
        if ($n -gt 0 -and $n -le 60) { [EmpScan]::Load($State) | ForEach-Object { "  0x{0:X}" -f $_ } }
        return
    }

    $hasInt   = $PSBoundParameters.ContainsKey('Int')
    $hasFloat = $PSBoundParameters.ContainsKey('Float')
    if (-not ($hasInt -or $hasFloat)) { throw "give -Int N or -Float N with -First or -Next" }
    if ($hasFloat) {
        $Int = [BitConverter]::ToInt32([BitConverter]::GetBytes([single]$Float), 0)
        "(scanning float {0} as bit pattern 0x{1:X8})" -f $Float, $Int
    }

    if ($First) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $n = $scan.Scan($Int, $Width, $IncludeImage.IsPresent, $State)
        "{0:N0} candidate(s) holding {1} (width {2})  ({3:N1}s)" -f $n, $Int, $Width, $sw.Elapsed.TotalSeconds
        "now CHANGE it in game, then:  .\scanmem.ps1 -Next -Int <new value>"
        return
    }
    if ($Next) {
        if (-not (Test-Path $State)) { throw "no $State - run -First first" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $n = $scan.Refine($Int, $Width, $State)
        "{0:N0} remain  ({1:N1}s)" -f $n, $sw.Elapsed.TotalSeconds
        if ($n -le 40 -and $n -gt 0) { [EmpScan]::Load($State) | ForEach-Object { "  0x{0:X}" -f $_ } }
        return
    }
    throw "pass -First or -Next (or -Read/-Dump/-Watch)"
}
finally { $scan.Close() }
