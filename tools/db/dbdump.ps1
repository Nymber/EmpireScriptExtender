<#
  dbdump.ps1 - print the rows of an Empire DB table file as readable values.

  Companion to dbcheck.ps1. dbcheck says whether a file PARSES; this says what
  it actually CONTAINS, which is what you need when the structure is fine but a
  foreign key points at something that does not exist (the game then refuses to
  start, with a clean exit and no crash record).

  Usage:
    .\dbdump.ps1 -File <path>                 # uses the folder name as table
    .\dbdump.ps1 -File <path> -Max 5
#>
param(
    [Parameter(Mandatory=$true)][string]$File,
    [int]$Max = 200,
    [string]$Schema
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $Schema) { $Schema = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'Total war empire tools\SaveParser\Data\master_schema.xml') }

[xml]$xml = Get-Content $Schema
$table = Split-Path (Split-Path $File -Parent) -Leaf
$defs = @()
foreach ($t in $xml.SelectNodes("//table")) {
    $n = $t.table_name; if (-not $n) { $n = $t.name }
    if ($n -ne $table) { continue }
    $fields = @()
    foreach ($f in $t.SelectNodes("field")) {
        $fields += [pscustomobject]@{ Name = $f.name; Type = $f.type; FKey = $f.fkey }
    }
    $defs += ,[pscustomobject]@{ Version = $t.table_version; Fields = $fields }
}
if (-not $defs) { Write-Output "no schema for '$table'"; exit }

$b = [System.IO.File]::ReadAllBytes($File)

function Parse($fields) {
    $pos = 1
    $rows = [BitConverter]::ToInt32($b,$pos); $pos += 4
    $out = @()
    for ($r = 0; $r -lt $rows; $r++) {
        $vals = @()
        foreach ($f in $fields) {
            switch -Wildcard ($f.Type) {
                'optstring*' {
                    $m = $b[$pos]; $pos++
                    if ($m -eq 1) {
                        $len = [BitConverter]::ToUInt16($b,$pos); $pos += 2
                        $vals += [System.Text.Encoding]::Unicode.GetString($b,$pos,$len*2); $pos += $len*2
                    } elseif ($m -eq 0) { $vals += '(none)' } else { return $null }
                }
                'string*' {
                    if ($pos + 2 -gt $b.Length) { return $null }
                    $len = [BitConverter]::ToUInt16($b,$pos); $pos += 2
                    if ($pos + $len*2 -gt $b.Length) { return $null }
                    $vals += [System.Text.Encoding]::Unicode.GetString($b,$pos,$len*2); $pos += $len*2
                }
                'boolean' { $vals += [bool]$b[$pos]; $pos += 1 }
                'int'     { $vals += [BitConverter]::ToInt32($b,$pos); $pos += 4 }
                'float'   { $vals += [BitConverter]::ToSingle($b,$pos); $pos += 4 }
                default   { $vals += ('?' + $b[$pos]); $pos += 4 }
            }
            if ($pos -gt $b.Length) { return $null }
        }
        $out += ,$vals
    }
    if ($pos -ne $b.Length) { return $null }
    return ,$out
}

foreach ($d in $defs) {
    $rows = Parse $d.Fields
    if ($null -eq $rows) { continue }
    Write-Output ("table {0}  (schema v{1}, {2} fields, {3} rows)" -f $table, $d.Version, $d.Fields.Count, $rows.Count)
    Write-Output ("columns: " + (($d.Fields | ForEach-Object { $_.Name + $(if ($_.FKey) { "->" + $_.FKey } else { "" }) }) -join " | "))
    Write-Output ""
    $i = 0
    foreach ($r in $rows) {
        Write-Output ("  " + ($r -join " | "))
        if (++$i -ge $Max) { Write-Output ("  ... ({0} more)" -f ($rows.Count - $Max)); break }
    }
    exit
}
Write-Output "no schema version fits this file"
