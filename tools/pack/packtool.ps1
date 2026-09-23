<#
  packtool.ps1 - find and extract files from Empire .pack archives.

  Written because list_pack.ps1 mis-parses this format. The trap: a vanilla pack
  has a DEPENDENCY BLOCK between the header and the file index, and skipping it
  yields offsets that are wrong by exactly deps_len bytes - you get plausible
  looking garbage rather than an obvious failure.

  PFH0 layout:
     "PFH0"            4 bytes
     type              int32   (0 boot, 1 release, 2 patch, 3 mod, 4 movie)
     deps_count        int32
     deps_len          int32   <-- the byte length of the dependency block
     files_count       int32
     index_len         int32
     [dependency block]        deps_len bytes
     [index]                   index_len bytes: per file -> int32 size, ASCII path, 0x00
     [file blobs]              concatenated, in index order

  Data therefore starts at 24 + deps_len + index_len.

  Usage:
    .\packtool.ps1 -Find panelmanager
    .\packtool.ps1 -Find export_triggers -Extract -Out C:\temp
    .\packtool.ps1 -Pack patch2.pack -Find ui\        -- limit to one pack
#>
param(
    [Parameter(Mandatory=$true)][string]$Find,
    [switch]$Extract,
    [string]$Out = ".",
    [string]$Pack,
    [string]$GameDir
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $GameDir) { $GameDir = (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) }

function Read-PackIndex([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    $br = New-Object System.IO.BinaryReader($fs)
    try {
        $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        if ($magic -ne 'PFH0') { return @() }
        $null      = $br.ReadInt32()          # type
        $null      = $br.ReadInt32()          # deps_count
        $depsLen   = $br.ReadInt32()
        $fileCount = $br.ReadInt32()
        $indexLen  = $br.ReadInt32()

        $headerEnd = $fs.Position             # 24
        $fs.Position = $headerEnd + $depsLen  # skip the dependency block
        $dataAt = $headerEnd + $depsLen + $indexLen

        $out = New-Object System.Collections.Generic.List[object]
        $off = $dataAt
        for ($i = 0; $i -lt $fileCount; $i++) {
            $size = $br.ReadInt32()
            $sb = New-Object System.Collections.Generic.List[byte]
            while ($true) { $b = $br.ReadByte(); if ($b -eq 0) { break }; $sb.Add($b) }
            $p = [System.Text.Encoding]::ASCII.GetString($sb.ToArray())
            $out.Add([pscustomobject]@{ Pack=$path; Path=$p; Size=$size; Offset=$off })
            $off += $size
        }
        return $out
    } finally { $br.Close(); $fs.Close() }
}

$packs = if ($Pack) { @(Join-Path $GameDir "data\$Pack") }
         else { Get-ChildItem (Join-Path $GameDir 'data') -Filter *.pack | ForEach-Object { $_.FullName } }

$hits = @()
foreach ($p in $packs) {
    if (-not (Test-Path $p)) { continue }
    foreach ($e in (Read-PackIndex $p)) { if ($e.Path -like "*$Find*") { $hits += $e } }
}

if (-not $hits) { Write-Output "no match for '$Find'"; return }

foreach ($h in $hits) {
    Write-Output ("{0,-20} {1,-52} {2,9:N0} bytes" -f (Split-Path $h.Pack -Leaf), $h.Path, $h.Size)
    if ($Extract) {
        $fs = [System.IO.File]::OpenRead($h.Pack)
        try {
            $fs.Position = $h.Offset
            $buf = New-Object byte[] $h.Size
            $read = $fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Close() }
        if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force -Path $Out | Out-Null }
        $name = ($h.Path -replace '[\\/:]', '_')
        $dest = Join-Path $Out $name
        [System.IO.File]::WriteAllBytes($dest, $buf)
        # a Lua chunk must start 1B 4C 75 61 - cheap sanity check that the
        # offset maths was right, since a bad offset yields plausible garbage
        $sig = ($buf[0..3] | ForEach-Object { "{0:X2}" -f $_ }) -join ' '
        $note = if ($sig -eq '1B 4C 75 61') { 'Lua 5.1 bytecode' } else { "sig $sig" }
        Write-Output ("    -> {0}  ({1}, {2:N0} bytes)" -f $dest, $note, $read)
    }
}
