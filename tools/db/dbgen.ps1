<#
  dbgen.ps1 - WRITE an Empire DB table file from plain text rows.

  The counterpart to dbcheck (does it parse?) and dbdump (what is in it?).
  Authoring table files by hand is the last hand-cranked step in adding a
  commodity, and doing it by hand is how a field ends up encoded as the wrong
  type - which the game punishes by exiting cleanly before the main menu with
  no crash record at all.

  FORMAT WRITTEN
    [byte version][int32 rowCount][rows]
    per field, by schema type:
      string / string_ascii     uint16 charCount + UTF-16LE
      optstring*                1 flag byte; if 1, uint16 + UTF-16LE
      int                       int32
      float                     float32
      boolean                   1 byte

  INPUT
    Pipe-separated, one row per line. Blank lines and # comments ignored.
    An empty field, or the literal (none), means "absent" for an optstring.

      res_rum|10|1.2

  SELF-TEST
    -Verify <file> regenerates the rows and compares against that file byte for
    byte. Round-tripping an existing table is the only real proof the encoder
    matches the engine's expectations, so use it whenever the schema is new.

  Usage
    .\dbgen.ps1 -Table commodities_tables -In rows.txt -Out zzz_x_commodities
    .\dbgen.ps1 -Table commodities_tables -In rows.txt -Verify <existing file>
#>
param(
    [Parameter(Mandatory=$true)][string]$Table,
    [Parameter(Mandatory=$true)][string]$In,
    [string]$Out,
    [string]$Verify,
    [int]$SchemaVersion = 0,
    # master_schema.xml sometimes holds SEVERAL definitions under the same
    # version number (e.g. commodities_tables has a `string` and a
    # `string_ascii` variant; campaign_map_slots has a 5- and a 6-field one).
    # dbdump picks whichever parses; a writer cannot, so say which to use.
    [int]$FieldCount = 0,
    [byte]$VersionByte = 1,
    [string]$Schema
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $Schema) { $Schema = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'Total war empire tools\SaveParser\Data\master_schema.xml') }

$ErrorActionPreference = 'Stop'
if (-not $Out -and -not $Verify) { throw "pass -Out or -Verify" }

[xml]$xml = Get-Content $Schema
$candidates = @()
foreach ($t in $xml.SelectNodes("//table")) {
    $n = $t.table_name; if (-not $n) { $n = $t.name }
    if ($n -ne $Table) { continue }
    if ([int]$t.table_version -ne $SchemaVersion) { continue }
    $f = @()
    foreach ($fl in $t.SelectNodes("field")) { $f += [pscustomobject]@{ Name = $fl.name; Type = $fl.type } }
    $candidates += ,$f
}
if (-not $candidates) { throw "no schema for $Table version $SchemaVersion" }

if ($FieldCount -gt 0) {
    $match = @($candidates | Where-Object { $_.Count -eq $FieldCount })
    if (-not $match) {
        throw ("no {0} v{1} definition with {2} fields (available: {3})" -f $Table, $SchemaVersion, $FieldCount,
               (($candidates | ForEach-Object { $_.Count }) -join ', '))
    }
    $fields = $match[0]
} else {
    $fields = $candidates[0]
    if ($candidates.Count -gt 1) {
        Write-Host ("NOTE: {0} v{1} has {2} definitions ({3} fields); using the first. Pass -FieldCount to choose." -f `
            $Table, $SchemaVersion, $candidates.Count, (($candidates | ForEach-Object { $_.Count }) -join '/')) -ForegroundColor Yellow
    }
}

Write-Host ("{0} v{1}: {2} fields -> {3}" -f $Table, $SchemaVersion, $fields.Count,
            (($fields | ForEach-Object { "$($_.Name):$($_.Type)" }) -join ', '))

$rows = @()
foreach ($line in (Get-Content $In)) {
    $s = $line.Trim()
    if (-not $s -or $s.StartsWith('#')) { continue }
    $parts = $s -split '\|'
    if ($parts.Count -ne $fields.Count) {
        throw ("row has {0} field(s), schema wants {1}: {2}" -f $parts.Count, $fields.Count, $s)
    }
    $rows += ,$parts
}
if ($rows.Count -eq 0) { throw "no rows in $In" }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([byte]$VersionByte)
$bw.Write([int32]$rows.Count)

foreach ($row in $rows) {
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $v = $row[$i].Trim()
        switch -Wildcard ($fields[$i].Type) {
            'optstring*' {
                # "absent" is a single 0 byte - NOT a zero-length string, which
                # is a different value and shifts every later field.
                if ($v -eq '' -or $v -eq '(none)') { $bw.Write([byte]0) }
                else {
                    $bw.Write([byte]1)
                    $bw.Write([uint16]$v.Length)
                    $bw.Write([System.Text.Encoding]::Unicode.GetBytes($v))
                }
            }
            'string*' {
                $bw.Write([uint16]$v.Length)
                $bw.Write([System.Text.Encoding]::Unicode.GetBytes($v))
            }
            'boolean' { $bw.Write([byte]([int](($v -eq '1') -or ($v -eq 'true')))) }
            'int'     { $bw.Write([int32]$v) }
            'float'   { $bw.Write([single]([double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture))) }
            default   { throw "unhandled field type $($fields[$i].Type)" }
        }
    }
}
$bw.Flush()
$bytes = $ms.ToArray()
$bw.Close()

if ($Verify) {
    $want = [System.IO.File]::ReadAllBytes($Verify)
    $same = ($want.Length -eq $bytes.Length)
    if ($same) { for ($i = 0; $i -lt $want.Length; $i++) { if ($want[$i] -ne $bytes[$i]) { $same = $false; break } } }
    if ($same) {
        Write-Host ("VERIFIED byte-identical to {0} ({1} bytes, {2} rows)" -f (Split-Path $Verify -Leaf), $bytes.Length, $rows.Count) -ForegroundColor Green
        exit 0
    }
    Write-Host ("MISMATCH: generated {0} bytes, existing {1} bytes" -f $bytes.Length, $want.Length) -ForegroundColor Red
    $n = [Math]::Min($want.Length, $bytes.Length)
    for ($i = 0; $i -lt $n; $i++) {
        if ($want[$i] -ne $bytes[$i]) { Write-Host ("first difference at offset {0}: existing {1:X2}, generated {2:X2}" -f $i, $want[$i], $bytes[$i]); break }
    }
    exit 1
}

[System.IO.File]::WriteAllBytes($Out, $bytes)
Write-Host ("wrote {0} ({1} bytes, {2} rows)" -f $Out, $bytes.Length, $rows.Count) -ForegroundColor Green
