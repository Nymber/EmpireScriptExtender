<#
  dbcheck.ps1 - validate Empire DB table files against master_schema.xml.

  A malformed DB row does not produce an error message - the game either ignores
  the table or refuses to start (a CLEAN EXIT before the main menu, no crash
  record). So the only practical test is the one this project already uses:
  parse the file with a candidate schema and require it to consume EXACTLY the
  whole file, zero bytes left over.

  master_schema.xml often lists SEVERAL versions per table; this tries them all
  and reports which (if any) fits. "no version fits" means the file is malformed
  or uses a schema the reference does not have.

  Empire DB layout:  [byte version][int32 row count][rows...]
  Field encodings:
    string / string_ascii        uint16 char count, then UTF-16LE chars
    optstring / optstring_ascii  byte 0 (absent) | byte 1 then a string
    boolean                      1 byte
    int                          4 bytes
    float                        4 bytes

  Usage:
    .\dbcheck.ps1 -Path <file-or-dir>
    .\dbcheck.ps1 -Path ..\..\GhidraProjects\new_commodity_pack\staged\db
#>
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Schema
)

# Resolve the install location. $PSScriptRoot is EMPTY inside param(),
# so this has to happen in the body, not as a parameter default.
if (-not $Schema) { $Schema = (Join-Path (& (Join-Path $PSScriptRoot '..\..\empire_paths.ps1') -Quiet) 'Total war empire tools\SaveParser\Data\master_schema.xml') }

[xml]$xml = Get-Content $Schema
# table name -> list of { version, fields[] }
$defs = @{}
foreach ($t in $xml.SelectNodes("//table")) {
    $name = $t.table_name; if (-not $name) { $name = $t.name }
    if (-not $name) { continue }
    $fields = @()
    foreach ($f in $t.SelectNodes("field")) { $fields += $f.type }
    if (-not $defs.ContainsKey($name)) { $defs[$name] = @() }
    $defs[$name] += ,[pscustomobject]@{ Version = $t.table_version; Fields = $fields }
}

function Test-Table($bytes, $fields) {
    $pos = 1
    if ($bytes.Length -lt 5) { return $null }
    $rows = [BitConverter]::ToInt32($bytes,$pos); $pos += 4
    if ($rows -lt 0 -or $rows -gt 200000) { return $null }
    for ($r = 0; $r -lt $rows; $r++) {
        foreach ($ft in $fields) {
            switch -Wildcard ($ft) {
                'optstring*' {
                    if ($pos -ge $bytes.Length) { return $null }
                    $m = $bytes[$pos]; $pos++
                    if ($m -eq 1) {
                        if ($pos + 2 -gt $bytes.Length) { return $null }
                        $len = [BitConverter]::ToUInt16($bytes,$pos); $pos += 2 + $len*2
                    } elseif ($m -ne 0) { return $null }
                }
                'string*' {
                    if ($pos + 2 -gt $bytes.Length) { return $null }
                    $len = [BitConverter]::ToUInt16($bytes,$pos); $pos += 2 + $len*2
                }
                'boolean' { $pos += 1 }
                'int'     { $pos += 4 }
                'float'   { $pos += 4 }
                default   { $pos += 4 }
            }
            if ($pos -gt $bytes.Length) { return $null }
        }
    }
    if ($pos -eq $bytes.Length) { return $rows }
    return $null
}

$files = if (Test-Path $Path -PathType Container) { Get-ChildItem $Path -Recurse -File } else { Get-Item $Path }

foreach ($f in $files) {
    # table name comes from the CONTAINING FOLDER, not the file name - mod files
    # are deliberately named differently so they merge instead of overriding
    $table = Split-Path (Split-Path $f.FullName -Parent) -Leaf
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not $defs.ContainsKey($table)) {
        Write-Output ("{0,-52} NO SCHEMA for '{1}'" -f $f.Name, $table); continue
    }
    $hit = $null
    foreach ($d in $defs[$table]) {
        $rows = Test-Table $bytes $d.Fields
        if ($null -ne $rows) { $hit = [pscustomobject]@{ V = $d.Version; Rows = $rows; N = $d.Fields.Count }; break }
    }
    if ($hit) {
        Write-Output ("{0,-52} OK   v{1} ({2} fields, {3} rows)" -f $f.Name, $hit.V, $hit.N, $hit.Rows)
    } else {
        $tried = ($defs[$table] | ForEach-Object { "v$($_.Version):$($_.Fields.Count)f" }) -join ' '
        Write-Output ("{0,-52} **MALFORMED** - no version fits ({1} bytes). Tried {2}" -f $f.Name, $bytes.Length, $tried)
    }
}
