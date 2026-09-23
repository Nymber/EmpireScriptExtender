<#
  dbfk.ps1 - validate FOREIGN KEYS in mod DB tables against the game's own data.

  WHY THIS EXISTS
    A dangling foreign key does not produce an error message. The game exits
    CLEANLY before the main menu - window appears, vanishes, no crash record,
    preferences written as if you had quit normally. Exactly that cost a long
    debugging session: building_culture_variants.culture is an FK to
    cultures_tables.key (5 valid values) but had been generated from a FACTION
    list, so 120 of its 123 rows pointed at rows that do not exist.

    master_schema.xml already declares every FK (fkey='cultures_tables.key'),
    so this can be checked automatically BEFORE launching the game.

  HOW
    1. Index the key universe: for every table referenced by an FK, read the
       vanilla version out of the .pack files and collect its key column.
    2. Parse each mod table and check every FK value resolves.

  Usage
    .\dbfk.ps1 -Path ..\..\GhidraProjects\new_commodity_pack\staged\db
    .\dbfk.ps1 -Path <dir> -Verbose      # also list the valid key sets
#>
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$GameDir,
    [string]$Schema,
    [switch]$ShowKeys
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $GameDir) { $GameDir = (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) }
if (-not $Schema) { $Schema = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'Total war empire tools\SaveParser\Data\master_schema.xml') }

$ErrorActionPreference = 'Stop'
[xml]$xml = Get-Content $Schema

# ---- schema: table -> versions -> fields (name/type/fkey) -------------------
$defs = @{}
foreach ($t in $xml.SelectNodes("//table")) {
    $n = $t.table_name; if (-not $n) { $n = $t.name }
    if (-not $n) { continue }
    $fields = @()
    foreach ($f in $t.SelectNodes("field")) {
        $fields += [pscustomobject]@{ Name=$f.name; Type=$f.type; FKey=$f.fkey }
    }
    if (-not $defs.ContainsKey($n)) { $defs[$n] = @() }
    $defs[$n] += ,[pscustomobject]@{ Version=$t.table_version; Fields=$fields }
}

# ---- pack reading (PFH0: header, DEPENDENCY BLOCK, index, blobs) ------------
function Read-PackIndex([string]$packPath) {
    $fs = [System.IO.File]::OpenRead($packPath); $br = New-Object System.IO.BinaryReader($fs)
    try {
        if ([System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) -ne 'PFH0') { return @() }
        $null=$br.ReadInt32(); $null=$br.ReadInt32(); $depsLen=$br.ReadInt32()
        $count=$br.ReadInt32(); $indexLen=$br.ReadInt32()
        $headerEnd = $fs.Position
        $fs.Position = $headerEnd + $depsLen          # skip deps or every offset is wrong
        $off = $headerEnd + $depsLen + $indexLen
        $out = New-Object System.Collections.Generic.List[object]
        for ($i=0; $i -lt $count; $i++) {
            $size = $br.ReadInt32()
            $sb = New-Object System.Collections.Generic.List[byte]
            while ($true) { $b = $br.ReadByte(); if ($b -eq 0) { break }; $sb.Add($b) }
            $out.Add([pscustomobject]@{
                Path=[System.Text.Encoding]::ASCII.GetString($sb.ToArray()); Size=$size; Offset=$off })
            $off += $size
        }
        return $out
    } finally { $br.Close(); $fs.Close() }
}

function Get-PackBytes($packPath, $entry) {
    $fs = [System.IO.File]::OpenRead($packPath)
    try { $fs.Position = $entry.Offset; $buf = New-Object byte[] $entry.Size; $null = $fs.Read($buf,0,$buf.Length); return $buf }
    finally { $fs.Close() }
}

# ---- table parsing ----------------------------------------------------------
function Parse-Table($bytes, $fields) {
    if ($bytes.Length -lt 5) { return $null }
    $pos = 1
    $rows = [BitConverter]::ToInt32($bytes,$pos); $pos += 4
    if ($rows -lt 0 -or $rows -gt 500000) { return $null }
    $out = New-Object System.Collections.Generic.List[object]
    for ($r=0; $r -lt $rows; $r++) {
        $vals = @()
        foreach ($f in $fields) {
            switch -Wildcard ($f.Type) {
                'optstring*' {
                    if ($pos -ge $bytes.Length) { return $null }
                    $m = $bytes[$pos]; $pos++
                    if ($m -eq 1) {
                        if ($pos+2 -gt $bytes.Length) { return $null }
                        $len=[BitConverter]::ToUInt16($bytes,$pos); $pos+=2
                        if ($pos+$len*2 -gt $bytes.Length) { return $null }
                        $vals += [System.Text.Encoding]::Unicode.GetString($bytes,$pos,$len*2); $pos += $len*2
                    } elseif ($m -eq 0) { $vals += $null } else { return $null }
                }
                'string*' {
                    if ($pos+2 -gt $bytes.Length) { return $null }
                    $len=[BitConverter]::ToUInt16($bytes,$pos); $pos+=2
                    if ($pos+$len*2 -gt $bytes.Length) { return $null }
                    $vals += [System.Text.Encoding]::Unicode.GetString($bytes,$pos,$len*2); $pos += $len*2
                }
                'boolean' { $pos += 1; $vals += $null }
                default   { $pos += 4; $vals += $null }    # int / float
            }
            if ($pos -gt $bytes.Length) { return $null }
        }
        $out.Add($vals)
    }
    if ($pos -ne $bytes.Length) { return $null }
    return ,$out
}

# try every schema version, return the one that consumes the file exactly
function Parse-Any($bytes, $tableName) {
    if (-not $defs.ContainsKey($tableName)) { return $null }
    foreach ($d in $defs[$tableName]) {
        $rows = Parse-Table $bytes $d.Fields
        if ($null -ne $rows) { return [pscustomobject]@{ Def=$d; Rows=$rows } }
    }
    return $null
}

# ---- 1. work out which tables we need keys from -----------------------------
$modFiles = Get-ChildItem $Path -Recurse -File
$needed = @{}
foreach ($mf in $modFiles) {
    $tbl = Split-Path (Split-Path $mf.FullName -Parent) -Leaf
    if (-not $defs.ContainsKey($tbl)) { continue }
    foreach ($d in $defs[$tbl]) {
        foreach ($f in $d.Fields) {
            if ($f.FKey) {
                $tgt = ($f.FKey -split '\.')[0]
                if (-not [string]::IsNullOrEmpty($tgt)) { $needed[$tgt] = $true }
            }
        }
    }
}
Write-Host ("FK targets to index: {0}" -f $needed.Keys.Count)

# ---- 2. build the key universe from the packs (+ the mod's own tables) ------
$universe = @{}
$packs = Get-ChildItem (Join-Path $GameDir 'data') -Filter *.pack | Sort-Object Name
foreach ($p in $packs) {
    $idx = $null
    try { $idx = Read-PackIndex $p.FullName } catch { continue }
    foreach ($e in $idx) {
        # pack paths look like db\<table>\<file>; anything else (text\, UI\) is
        # not a table, and a short path would yield a null folder
        $parts = $e.Path -split '\\'
        if ($parts.Count -lt 3 -or $parts[0] -ne 'db') { continue }
        $folder = $parts[1]
        if ([string]::IsNullOrEmpty($folder) -or -not $needed.ContainsKey($folder)) { continue }
        $bytes = Get-PackBytes $p.FullName $e
        $parsed = Parse-Any $bytes $folder
        if (-not $parsed) { continue }
        if (-not $universe.ContainsKey($folder)) { $universe[$folder] = @{} }
        foreach ($row in $parsed.Rows) { if ($row[0]) { $universe[$folder][$row[0]] = $true } }
    }
}
# the mod's own tables also supply keys (e.g. our building_levels for our FKs)
foreach ($mf in $modFiles) {
    $tbl = Split-Path (Split-Path $mf.FullName -Parent) -Leaf
    if (-not $needed.ContainsKey($tbl)) { continue }
    $parsed = Parse-Any ([System.IO.File]::ReadAllBytes($mf.FullName)) $tbl
    if (-not $parsed) { continue }
    if (-not $universe.ContainsKey($tbl)) { $universe[$tbl] = @{} }
    foreach ($row in $parsed.Rows) { if ($row[0]) { $universe[$tbl][$row[0]] = $true } }
}
foreach ($k in ($universe.Keys | Sort-Object)) {
    Write-Host ("  {0,-46} {1,6} keys" -f $k, $universe[$k].Count)
    if ($ShowKeys) { Write-Host ("      " + (($universe[$k].Keys | Sort-Object | Select-Object -First 12) -join ', ')) }
}

# ---- 3. check every FK in the mod tables -----------------------------------
Write-Host ""
$problems = 0
foreach ($mf in $modFiles) {
    $tbl = Split-Path (Split-Path $mf.FullName -Parent) -Leaf
    $parsed = Parse-Any ([System.IO.File]::ReadAllBytes($mf.FullName)) $tbl
    if (-not $parsed) { Write-Host ("{0,-46} (no schema fits - run dbcheck.ps1)" -f $mf.Name); continue }

    $bad = @()
    for ($ci = 0; $ci -lt $parsed.Def.Fields.Count; $ci++) {
        $fld = $parsed.Def.Fields[$ci]
        if (-not $fld.FKey) { continue }
        $targetTable = ($fld.FKey -split '\.')[0]
        if ([string]::IsNullOrEmpty($targetTable)) { continue }
        if (-not $universe.ContainsKey($targetTable)) {
            $bad += [pscustomobject]@{ Col=$fld.Name; Target=$fld.FKey; Value='(target table not indexed)'; N=0 }
            continue
        }
        $missing = @{}
        foreach ($row in $parsed.Rows) {
            $v = $row[$ci]
            if ($null -eq $v -or $v -eq '') { continue }        # absent optional = fine
            if (-not $universe[$targetTable].ContainsKey($v)) {
                if (-not $missing.ContainsKey($v)) { $missing[$v] = 0 }
                $missing[$v]++
            }
        }
        foreach ($m in $missing.Keys) { $bad += [pscustomobject]@{ Col=$fld.Name; Target=$fld.FKey; Value=$m; N=$missing[$m] } }
    }

    if ($bad.Count -eq 0) {
        Write-Host ("{0,-46} OK  ({1} rows)" -f $mf.Name, $parsed.Rows.Count) -ForegroundColor Green
    } else {
        $problems += $bad.Count
        Write-Host ("{0,-46} ** {1} BROKEN FK VALUE(S) **" -f $mf.Name, $bad.Count) -ForegroundColor Red
        foreach ($x in ($bad | Sort-Object Col, Value | Select-Object -First 12)) {
            Write-Host ("      {0} -> {1}  : '{2}' does not exist ({3} row(s))" -f $x.Col, $x.Target, $x.Value, $x.N)
        }
        if ($bad.Count -gt 12) { Write-Host ("      ... and {0} more" -f ($bad.Count - 12)) }
    }
}
Write-Host ""
if ($problems -eq 0) { Write-Host "All foreign keys resolve." -ForegroundColor Green }
else { Write-Host ("{0} broken foreign key value(s) - the game will refuse to start (clean exit, no crash record)." -f $problems) -ForegroundColor Red }
