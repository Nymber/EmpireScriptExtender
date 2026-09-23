<#
  release.ps1 - build a clean ESE release zip.

  Includes the verified prebuilt DLL so players do not need a compiler.
  Excludes generated packs, staging trees, memory dumps, symbols and logs.

  Usage:
    .\release.ps1
    .\release.ps1 -OutputPath .\dist\EmpireScriptExtender.zip
#>
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutputPath) { $OutputPath = Join-Path $env:TEMP 'EmpireScriptExtender-release.zip' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

$dll = Join-Path $root 'src\dinput8.dll'
if (-not (Test-Path $dll)) { throw 'src\dinput8.dll is missing. Run .\empire.ps1 build before making a release.' }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$stage = Join-Path $tempRoot ('ese-release-' + [guid]::NewGuid().ToString('N'))
$stageFull = [IO.Path]::GetFullPath($stage)
if (-not $stageFull.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe temporary stage path: $stageFull"
}
$package = Join-Path $stage 'EmpireScriptExtender'

function Is-Excluded([string]$relative, [IO.FileInfo]$file) {
    $r = $relative -replace '/', '\'
    if ($r -match '(^|\\)(\.git|staged|bin|_scratch|_probe)(\\|$)') { return $true }
    if ($file.Extension -in @('.pack','.pdb','.lib','.obj','.exp','.log')) { return $true }
    if ($file.Name -match '\.(bak|orig|old|prev|tmp)(_|$|\.)') { return $true }
    if ($file.Name -like '_*.ps1' -and $r -like 'src\*') { return $true }
    return $false
}

try {
    New-Item -ItemType Directory -Force -Path $package | Out-Null
    $includeRoots = @(
        'ESE Manager.cmd','empire.ps1','empire_paths.ps1','empire_paths.rb',
        'release.ps1','cleanup.ps1','shell.ps1','README.md','INDEX.md',
        '.gitattributes','.gitignore','src','lua','config','docs','tools'
    )
    $copied = 0
    foreach ($name in $includeRoots) {
        $item = Get-Item -LiteralPath (Join-Path $root $name) -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $files = if ($item.PSIsContainer) { Get-ChildItem $item.FullName -Recurse -File } else { @($item) }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($root.Length).TrimStart('\')
            if (Is-Excluded $relative $file) { continue }
            $dest = Join-Path $package $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $dest
            $copied++
        }
    }

    if (-not (Test-Path (Join-Path $package 'src\dinput8.dll'))) { throw 'release lost the prebuilt DLL' }
    if (-not (Test-Path (Join-Path $package 'ESE Manager.cmd'))) { throw 'release lost the manager' }
    if (-not (Test-Path (Join-Path $package 'config\ese_commodities.txt'))) { throw 'release lost required trade UI config' }
    $forbidden = Get-ChildItem $package -Recurse -File | Where-Object { $_.Extension -eq '.pack' }
    if ($forbidden) { throw 'generated .pack file entered the release stage' }

    # Portability gate: personal paths in executable text make a release appear
    # portable while silently targeting the maintainer's machine. Standard
    # install fallbacks are allowed only in the dedicated path resolver.
    $textExtensions = @('.md','.ps1','.rb','.lua','.cmd','.txt','.json','.csv','.java','.py')
    foreach ($file in Get-ChildItem $package -Recurse -File | Where-Object { $_.Extension -in $textExtensions }) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $relative = $file.FullName.Substring($package.Length).TrimStart('\')
        $privateRoots = @('.' + 'claude', '.' + 'codex')
        $hasPrivateRoot = $false
        foreach ($marker in $privateRoots) {
            if ($text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hasPrivateRoot = $true
                break
            }
        }
        if ($text -match '(?i)[A-Z]:\\Users\\' -or $hasPrivateRoot) {
            throw "personal path entered release text: $relative"
        }
        if ($file.Name -ne 'empire_paths.ps1' -and $text -match '(?m)(?<![A-Za-z])[A-Z]:\\') {
            throw "absolute drive path outside the resolver: $relative"
        }
    }

    # Every local Markdown link must resolve inside the release, not merely in
    # a developer tree that contains excluded staging data.
    foreach ($file in Get-ChildItem $package -Recurse -Filter *.md -File) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
            $target = $match.Groups[1].Value.Trim().Trim('<','>')
            if ($target -match '^(?i:https?://|mailto:|#|codex:)') { continue }
            $target = ($target -split '#')[0]
            if (-not $target) { continue }
            $resolved = Join-Path $file.DirectoryName ($target -replace '/', '\')
            if (-not (Test-Path -LiteralPath $resolved)) {
                $relative = $file.FullName.Substring($package.Length).TrimStart('\')
                throw "broken Markdown link in ${relative}: $target"
            }
        }
    }

    $dllHash = (Get-FileHash (Join-Path $package 'src\dinput8.dll') -Algorithm SHA256).Hash
    @(
        'Empire Script Extender release manifest'
        "Created: $((Get-Date).ToString('o'))"
        "Files: $copied"
        "src/dinput8.dll SHA256: $dllHash"
        'Generated packs included: no'
        'Personal absolute paths: none'
        'Markdown relative links: verified'
    ) | Set-Content -LiteralPath (Join-Path $package 'RELEASE-MANIFEST.txt') -Encoding UTF8

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    if (Test-Path $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    Compress-Archive -LiteralPath $package -DestinationPath $OutputPath -CompressionLevel Optimal
    Write-Host "Release: $OutputPath" -ForegroundColor Green
    Write-Host "Files: $copied; DLL SHA-256: $dllHash"
    Write-Host 'Generated packs: none'
    Write-Host 'Portability and Markdown links: verified'
} finally {
    if (Test-Path $stageFull) { Remove-Item -LiteralPath $stageFull -Recurse -Force }
}
