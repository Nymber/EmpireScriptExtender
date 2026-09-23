<#
  shell.ps1 - a live terminal for toolkit commands and mod packs.

  Stays open. The first prompt is a menu. 1 runs a command. 2 installs or
  uninstalls a mod pack. A mod is a lua folder that contains install_pack.ps1
  and names itself in that script's comment header.

    .\shell.ps1                 # the menu
    .\shell.ps1 help            # the command list, then exit
    .\shell.ps1 help packtool   # one script, then exit
    .\shell.ps1 mods            # the mod list, then exit

  At the menu:
    1  commands                 then a script name, or help
    2  mods                     then install <mod> or uninstall <mod>
    help                        every command
    mods                        every mod
    quit                        leave
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$ArgsIn
)
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$Skip = '\\ghidra_12|' + [regex]::Escape('\tools\ui\_probe\') + '|\\src\\build\.ps1$'

function Get-CommentHelp([string]$path) {
    $lines = Get-Content $path -TotalCount 80 -ErrorAction SilentlyContinue
    if (-not $lines) { return '' }
    $buf = New-Object System.Collections.Generic.List[string]
    $in = $false
    foreach ($line in $lines) {
        if (-not $in) {
            if ($line -match '<#') { $in = $true }
            continue
        }
        if ($line -match '#>') { break }
        $buf.Add(($line -replace '^\s*', ''))
    }
    return ($buf -join "`n").Trim()
}

function Get-Usage([string]$help) {
    if (-not $help) { return @() }
    $take = $false
    $out = @()
    foreach ($line in ($help -split "`n")) {
        if ($line -match '^(USAGE|Usage|COMMANDS|EXAMPLES)\b') { $take = $true; $out += $line.Trim(); continue }
        if ($take -and $line -match '^(Notes|WHY|param\(|\[CmdletBinding)') { break }
        if ($take -and $line.Trim()) { $out += $line.Trim() }
    }
    if ($out) { return $out }
    return @($help -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
}

function Find-Docs([string]$name) {
    $docs = Join-Path $Root 'docs'
    if (-not (Test-Path $docs)) { return @() }
    $hits = Select-String -Path (Join-Path $docs '*.md') -Pattern ([regex]::Escape($name)) -List -ErrorAction SilentlyContinue
    $more = @()
    foreach ($extra in @('INDEX.md', 'README.md', 'lua\README.md')) {
        $p = Join-Path $Root $extra
        if ((Test-Path $p) -and (Select-String -Path $p -Pattern ([regex]::Escape($name)) -List -Quiet)) {
            $more += $extra
        }
    }
    return @($hits | ForEach-Object { 'docs\' + $_.Filename }) + $more
}

function Get-ModLabel([string]$help, [string]$folder) {
    $take = $false
    foreach ($line in ($help -split "`n")) {
        if ($line -match '^Mod\s+(.+)$') { return $Matches[1].Trim() }
        if ($line -match '^Mod\s*$') { $take = $true; continue }
        if ($take -and $line.Trim()) { return $line.Trim() }
        if ($take) { break }
    }
    return $folder
}

function Get-Scripts {
    Get-ChildItem $Root -Filter *.ps1 -Recurse -File |
        Where-Object { $_.FullName -notmatch $Skip } |
        Sort-Object FullName |
        ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length + 1)
            $help = Get-CommentHelp $_.FullName
            $isMod = $_.Name -eq 'install_pack.ps1'
            [pscustomobject]@{
                Name   = $_.BaseName
                Rel    = $rel
                Path   = $_.FullName
                Usage  = @(Get-Usage $help)
                Help   = $help
                Docs   = @(Find-Docs $_.Name)
                IsMod  = $isMod
                Folder = Split-Path -Parent $rel
                Mod    = $(if ($isMod) { Get-ModLabel $help (Split-Path -Leaf (Split-Path -Parent $rel)) } else { '' })
            }
        }
}

$Script:Catalog = @(Get-Scripts)

function Get-Commands {
    @($Script:Catalog | Where-Object { -not $_.IsMod -and $_.Name -ne 'shell' })
}

function Get-Mods {
    @($Script:Catalog | Where-Object { $_.IsMod })
}

function Resolve-Script([string]$name) {
    $hits = @(Get-Commands | Where-Object { $_.Name -eq $name -or $_.Rel -eq $name })
    if (-not $hits) {
        $hits = @(Get-Commands | Where-Object { $_.Name -like "$name*" -or $_.Rel -like "*$name*" })
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1) {
        Write-Host "more than one '$name':"
        $hits | ForEach-Object { Write-Host ("  {0}" -f $_.Rel) }
    }
    return $null
}

function Resolve-Mod([string]$name) {
    $hits = @(Get-Mods | Where-Object { $_.Mod -eq $name -or $_.Folder -eq $name })
    if (-not $hits) {
        $hits = @(Get-Mods | Where-Object {
            $_.Mod -like "*$name*" -or $_.Folder -like "*$name*"
        })
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1) {
        Write-Host "more than one '$name':"
        $hits | ForEach-Object { Write-Host ("  {0}  {1}" -f $_.Mod, $_.Folder) }
    }
    return $null
}

function Show-One($s) {
    Write-Host $s.Rel
    Write-Host ("  run   {0} [args]" -f $s.Name)
    if ($s.Usage) {
        Write-Host "  usage"
        $s.Usage | ForEach-Object { Write-Host "    $_" }
    }
    if ($s.Docs) {
        Write-Host "  docs"
        $s.Docs | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "  docs  (none - the comment header above is the help)"
    }
}

function Show-Help([string]$which) {
    if ($which) {
        $s = Resolve-Script $which
        if (-not $s) { Write-Host "no command named $which"; return }
        Show-One $s
        if ($s.Help) { Write-Host ""; Write-Host $s.Help }
        return
    }
    Write-Host "1 commands - type the name, then its arguments. 'empire' is the default."
    Write-Host ""
    foreach ($s in (Get-Commands)) {
        $line = $s.Usage | Select-Object -First 1
        Write-Host ("{0,-28} {1}" -f $s.Name, $line)
        Write-Host ("  {0}" -f $s.Rel)
        if ($s.Docs) { Write-Host ("  docs: {0}" -f ($s.Docs -join ', ')) }
        Write-Host ""
    }
    Write-Host 'help <name>   one command, its usage, and its help text'
    Write-Host "reload        rescan the tree"
    Write-Host "menu          back to the menu"
    Write-Host "quit          leave"
}

function Show-Mods {
    $mods = @(Get-Mods)
    Write-Host "2 mods - install or uninstall. The game must be closed."
    Write-Host ""
    if (-not $mods.Count) {
        Write-Host "no install_pack.ps1 under lua\"
        return
    }
    foreach ($m in $mods) {
        Write-Host ("{0,-28} {1}" -f ("install_pack  " + $m.Mod), $m.Folder)
    }
    Write-Host ""
    Write-Host "install <mod>       copy that mod's pack into data\"
    Write-Host "uninstall <mod>     remove that mod's pack from data\"
    Write-Host "menu                back to the menu"
}

function Show-Menu {
    Write-Host ""
    Write-Host "1  commands     launch a toolkit script"
    Write-Host "2  mods         install or uninstall a mod pack"
    Write-Host "help            list commands"
    Write-Host "mods            list mods"
    Write-Host "quit            leave"
}

function Invoke-Mod([string]$action, [string]$which) {
    if (-not $which) { Show-Mods; return }
    $m = Resolve-Mod $which
    if (-not $m) { Write-Host "no mod named $which"; Show-Mods; return }
    $arg = @()
    if ($action -eq 'uninstall') { $arg = @('-Uninstall') }
    Write-Host ("--- {0}  {1} {2}" -f $m.Mod, $m.Rel, ($arg -join ' '))
    & powershell -NoProfile -File $m.Path @arg
    Write-Host ("--- exit {0}" -f $LASTEXITCODE)
}

function Invoke-Line([string]$line) {
    $line = $line.Trim()
    if (-not $line) { return $true }
    $parts = $line -split '\s+', 2
    $cmd = $parts[0]
    $rest = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    switch ($cmd) {
        { $_ -in @('quit', 'exit') } { return $false }
        'reload' { $Script:Catalog = @(Get-Scripts); Write-Host ("{0} scripts" -f $Script:Catalog.Count); return $true }
        'menu'   { Show-Menu; return $true }
        'help'   { Show-Help $rest; return $true }
        '?'      { Show-Help $rest; return $true }
        'mods'   { Show-Mods; return $true }
        '1'      { if ($rest) { return Invoke-Line $rest }; Show-Help ''; return $true }
        '2'      { if ($rest) { return Invoke-Line $rest }; Show-Mods; return $true }
        'install'   { Invoke-Mod 'install' $rest; return $true }
        'uninstall' { Invoke-Mod 'uninstall' $rest; return $true }
    }
    $target = $cmd
    $forward = $rest
    if (-not (Resolve-Script $cmd)) {
        $target = 'empire'
        $forward = $line
    }
    $s = Resolve-Script $target
    if (-not $s) { Write-Host "unknown: $cmd  (1 lists commands, 2 lists mods)"; return $true }
    Write-Host ("--- {0} {1}" -f $s.Rel, $forward)
    & powershell -NoProfile -File $s.Path @($forward -split '\s+' | Where-Object { $_ })
    Write-Host ("--- exit {0}" -f $LASTEXITCODE)
    return $true
}

if ($ArgsIn -and $ArgsIn.Count) {
    Invoke-Line ($ArgsIn -join ' ') | Out-Null
    return
}

Write-Host ("toolkit shell - {0} commands, {1} mods." -f @(Get-Commands).Count, @(Get-Mods).Count)
Show-Menu
while ($true) {
    Write-Host -NoNewline 'etw> '
    $line = Read-Host
    if ($null -eq $line) { break }
    if (-not (Invoke-Line $line)) { break }
}