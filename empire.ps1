<#
  empire.ps1 - one entry point for every routine workflow.

  Before this, each task was a remembered sequence of tool invocations with
  hardcoded paths. Everything here resolves the install dynamically via
  empire_paths.ps1, so it works on any machine.

  COMMANDS
    install                      install/repair from the prebuilt DLL, then sync
    doctor                       read-only installation and live-runtime check
    update                       alias of the idempotent install command
    uninstall                    safely disable ESE and restore a proxy backup
    release [zip]                make a clean release archive with no packs
    mods                         list installed mods and activation state
    enable <id>                  enable a mod for the next Lua state
    disable <id>                 disable a mod for the next Lua state
    paths                        show the resolved install
    status                       what is deployed, is the game up, is ESE alive
    build                        build the ESE proxy DLL
    deploy                       build + deploy the DLL (hash verified)
    pack <stagedir> <name>       build a .pack from a staged tree
                                   -Deploy   also install it and hash-verify
    hipoly                       extract + subdivide + stage the unit corpus
                                   -Only <substr>   limit to matching units
                                   -Deploy          also pack and install
    lod <factor>                 rebuild the LOD distance-band pack
    launch [battle]              start Empire at the frontend menu, or boot
                                   straight into the supplied battle XML
                                   copies Lua and Tools into the install first
    arm                          install the first-person rig into a live battle
    shot [name]                  screenshot the game window
    restore                      undo the launch preference edit

  EXAMPLES
    .\empire.ps1 status
    .\empire.ps1 hipoly -Only euro_line -Deploy
    .\empire.ps1 deploy
    .\empire.ps1 launch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$Only,
    [switch]$Deploy,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

$E = & (Join-Path $PSScriptRoot 'empire_paths.ps1') -Json | ConvertFrom-Json
$Tools = $E.ToolsDir          # the PARENT folder (SaveParser, RPFM, Ghidra live there)
$EseDir = $E.EseDir
$ScriptTools = $E.ScriptTools

function Assert-GameClosed {
    if (Get-Process Empire -ErrorAction SilentlyContinue) {
        throw "Empire is running. Close it first - deploying while it is up either fails or is silently undone."
    }
}

function Copy-Tree([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { throw "missing $src" }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item (Join-Path $src '*') $dst -Recurse -Force
}

# The toolkit tree is what we edit. The game reads a different tree: autoexec
# from the install root, mod folders from EmpireScriptExtender\lua, and the
# Ruby/PowerShell helpers from EmpireScriptExtender\tools. Launch is the one
# moment both sides are known and the game is not holding the files.
function Sync-GameFiles {
    $kit = $E.KitDir
    $luaSrc = Join-Path $kit 'lua'
    $toolsSrc = Join-Path $kit 'tools'
    $docsSrc = Join-Path $kit 'docs'
    $configSrc = Join-Path $kit 'config'
    $luaDst = Join-Path $E.GameKitDir 'lua'
    $toolsDst = Join-Path $E.GameKitDir 'tools'
    $docsDst = Join-Path $E.GameKitDir 'docs'

    foreach ($d in @($luaDst, $toolsDst, $docsDst)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }

    $autoexec = @{
        'ese_autoexec.lua'        = Join-Path $luaSrc 'ese_autoexec.lua'
        'ese_battle_autoexec.lua' = Join-Path $luaSrc 'fp\ese_battle_autoexec.lua'
    }
    foreach ($name in $autoexec.Keys) {
        $src = $autoexec[$name]
        if (-not (Test-Path $src)) { throw "missing $src" }
        Copy-Item $src (Join-Path $E.GameDir $name) -Force
    }
    # Lua is one runtime: core, registry, manifests, and disabled mods must
    # arrive together so activation never leaves a partial live tree.
    Copy-Tree $luaSrc $luaDst
    "  lua (complete runtime)"
    # Mirror every supported tool category. Several mesh and DB tools resolve
    # ../../empire_paths from their own location, and vwm_json reads a pose file
    # from docs, so mirroring only a hand-picked subset made the live tools tree
    # look complete while leaving it unusable.
    foreach ($name in @('behavior', 'db', 'engine', 'game', 'mesh', 'pack',
                        'texture', 'trademod', 'ui')) {
        $src = Join-Path $toolsSrc $name
        if (Test-Path $src) {
            Copy-Tree $src (Join-Path $toolsDst $name)
            "  tools\$name"
        }
    }
    foreach ($name in @('ese_commodities.txt')) {
        $src = Join-Path $configSrc $name
        if (-not (Test-Path -LiteralPath $src)) { throw "missing runtime config $src" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $E.GameDir $name) -Force
    }
    foreach ($name in @('empire_paths.ps1', 'empire_paths.rb')) {
        Copy-Item -LiteralPath (Join-Path $kit $name) -Destination (Join-Path $E.GameKitDir $name) -Force
    }
    Copy-Tree $docsSrc $docsDst
    "  docs"
    "synced runtime config, Lua, Tools, path resolvers, and Docs into $($E.GameDir)"
}

function Get-EseMods {
    $registry = Join-Path $E.KitDir 'lua\ese_mods.lua'
    $items = @()
    foreach ($line in Get-Content -LiteralPath $registry) {
        if ($line -match "^\s*\{\s*id='([^']+)',\s*path='([^']+)',\s*enabled=(true|false)\s*\},?\s*$") {
            $items += [pscustomobject]@{
                Id = $Matches[1]
                Path = $Matches[2]
                Enabled = ($Matches[3] -eq 'true')
            }
        }
    }
    if (-not $items) { throw "No valid mod records in $registry" }
    return $items
}

function Set-EseModState([string]$Id, [bool]$Enabled) {
    if (-not $Id) { throw 'usage: empire.ps1 enable|disable <mod-id>' }
    $registry = Join-Path $E.KitDir 'lua\ese_mods.lua'
    $lines = [Collections.Generic.List[string]](Get-Content -LiteralPath $registry)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*\{\s*id='([^']+)',\s*path='([^']+)',\s*enabled=(true|false)\s*\},?\s*$" -and
            $Matches[1] -eq $Id) {
            $value = if ($Enabled) { 'true' } else { 'false' }
            $lines[$i] = "  { id='$($Matches[1])', path='$($Matches[2])', enabled=$value },"
            $found = $true
            break
        }
    }
    if (-not $found) { throw "Unknown mod '$Id'. Run .\empire.ps1 mods." }
    [IO.File]::WriteAllLines($registry, $lines, [Text.UTF8Encoding]::new($false))
    Sync-GameFiles
    $verb = if ($Enabled) { 'enabled' } else { 'disabled' }
    Write-Host "$Id $verb. The change applies when Empire creates the next campaign or battle state." -ForegroundColor Green
}

function Install-Pack([string]$src, [string]$name) {
    Assert-GameClosed
    $dst = Join-Path $E.DataDir $name
    Copy-Item $src $dst -Force
    $a = (Get-FileHash $src -Algorithm SHA256).Hash
    $b = (Get-FileHash $dst -Algorithm SHA256).Hash
    if ($a -ne $b) { throw "deploy verification FAILED for $name" }
    "deployed $name ({0:N1} MB) - hash verified" -f ((Get-Item $dst).Length / 1MB)
}

function Test-EseDll([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 0x100) { return $false }
        $pe = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($pe -lt 0 -or $pe + 6 -gt $bytes.Length) { return $false }
        if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x014C) { return $false }
        $marker = [Text.Encoding]::ASCII.GetBytes('ESE proxy')
        for ($i = 0; $i -le $bytes.Length - $marker.Length; $i++) {
            if ($bytes[$i] -ne $marker[0]) { continue }
            $same = $true
            for ($j = 1; $j -lt $marker.Length; $j++) {
                if ($bytes[$i + $j] -ne $marker[$j]) { $same = $false; break }
            }
            if ($same) { return $true }
        }
    } catch { return $false }
    return $false
}

function Get-EseArtifact {
    $dll = Join-Path $E.EseDir 'dinput8.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        Write-Host 'No prebuilt ESE DLL was found; building one from source...'
        & (Join-Path $E.EseDir 'build.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'ESE build failed' }
    }
    if (-not (Test-EseDll $dll)) {
        throw "The ESE DLL is missing, corrupt, or not 32-bit: $dll"
    }
    return $dll
}

function Install-Ese {
    Assert-GameClosed
    $artifact = Get-EseArtifact
    Sync-GameFiles

    $dest = $E.Dll
    $backup = Join-Path $E.GameDir 'dinput8_original.dll'
    if (Test-Path -LiteralPath $dest) {
        if (-not (Test-EseDll $dest)) {
            if (Test-Path -LiteralPath $backup) {
                $same = (Get-FileHash $dest -Algorithm SHA256).Hash -eq
                        (Get-FileHash $backup -Algorithm SHA256).Hash
                if (-not $same -and -not $Force) {
                    throw "Another mod owns dinput8.dll and a different backup already exists. Nothing was changed. Re-run with -Force only after deciding which proxy DLL must load first."
                }
            } else {
                Copy-Item -LiteralPath $dest -Destination $backup
                Write-Host 'Backed up the existing non-ESE dinput8.dll as dinput8_original.dll.'
            }
        }
    }

    Copy-Item -LiteralPath $artifact -Destination $dest -Force
    $srcHash = (Get-FileHash $artifact -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash $dest -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) { throw 'ESE DLL copy verification failed' }

    $manifest = [ordered]@{
        installedAt = (Get-Date).ToString('o')
        gameDir = $E.GameDir
        toolkitDir = $E.KitDir
        dllSha256 = $dstHash
    }
    New-Item -ItemType Directory -Force -Path $E.GameKitDir | Out-Null
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $E.GameKitDir 'install.json') -Encoding UTF8
    Write-Host ''
    Write-Host 'ESE installed successfully.' -ForegroundColor Green
    Write-Host "  Game: $($E.GameDir)"
    Write-Host '  Lua and helper tools: synchronized'
    Write-Host '  DLL: 32-bit ESE proxy, SHA-256 verified'
    Write-Host 'Next: run .\empire.ps1 launch'
}

function Uninstall-Ese {
    Assert-GameClosed
    $dest = $E.Dll
    $backup = Join-Path $E.GameDir 'dinput8_original.dll'
    if (Test-Path -LiteralPath $dest) {
        if (-not (Test-EseDll $dest)) {
            throw 'The installed dinput8.dll is not ESE. Refusing to remove another mod or system proxy.'
        }
        if (Test-Path -LiteralPath $backup) {
            Move-Item -LiteralPath $backup -Destination $dest -Force
            Write-Host 'Restored the pre-ESE dinput8.dll.'
        } else {
            Remove-Item -LiteralPath $dest -Force
            Write-Host 'Removed the ESE proxy DLL.'
        }
    } else {
        Write-Host 'ESE proxy DLL was already absent.'
    }

    foreach ($name in @('ese_autoexec.lua', 'ese_battle_autoexec.lua', 'ese_commodities.txt')) {
        $live = Join-Path $E.GameDir $name
        $source = if ($name -eq 'ese_autoexec.lua') {
            Join-Path $E.KitDir 'lua\ese_autoexec.lua'
        } elseif ($name -eq 'ese_battle_autoexec.lua') {
            Join-Path $E.KitDir 'lua\fp\ese_battle_autoexec.lua'
        } else {
            Join-Path $E.KitDir 'config\ese_commodities.txt'
        }
        if (Test-Path $live) {
            if ((Test-Path $source) -and
                ((Get-FileHash $live -Algorithm SHA256).Hash -eq (Get-FileHash $source -Algorithm SHA256).Hash)) {
                Remove-Item -LiteralPath $live -Force
            } else {
                Write-Warning "Left modified $name in place."
            }
        }
    }
    Remove-Item -LiteralPath (Join-Path $E.GameKitDir 'install.json') -Force -ErrorAction SilentlyContinue
    Write-Host 'Generated packs and the inert live mirror were left untouched.'
}

function Test-MirrorFile([string]$Source, [string]$Destination) {
    if (-not (Test-Path $Destination)) { return 'missing' }
    if (-not (Test-Path $Source)) { return 'source missing' }
    if ((Get-FileHash $Source -Algorithm SHA256).Hash -ne
        (Get-FileHash $Destination -Algorithm SHA256).Hash) { return 'out of date' }
    return 'ok'
}

function Get-MirrorTreeStatus([string]$Source, [string]$Destination) {
    if (-not (Test-Path $Source)) { return [pscustomobject]@{ Ok=$false; Detail='source missing' } }
    if (-not (Test-Path $Destination)) { return [pscustomobject]@{ Ok=$false; Detail='mirror missing' } }
    $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File)
    $missing = 0
    $different = 0
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        $live = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $live)) { $missing++; continue }
        if ((Get-FileHash $file.FullName -Algorithm SHA256).Hash -ne
            (Get-FileHash $live -Algorithm SHA256).Hash) { $different++ }
    }
    $ok = ($missing -eq 0 -and $different -eq 0)
    return [pscustomobject]@{
        Ok = $ok
        Detail = if ($ok) { "$($files.Count) files synchronized" } else { "$missing missing, $different out of date" }
    }
}

function Test-CommodityConfig {
    $config = Join-Path $E.KitDir 'config\ese_commodities.txt'
    $manifest = Join-Path $E.KitDir 'tools\trademod\chain_manifest.txt'
    if (-not (Test-Path $config) -or -not (Test-Path $manifest)) {
        return [pscustomobject]@{ Ok=$false; Detail='config or chain manifest missing' }
    }
    $expected = @('res_rum') + @(Get-Content $manifest | ForEach-Object {
        if ($_ -match '^COM\|([^|]+)\|') { $Matches[1] }
    })
    $actual = @()
    $raw = $null
    foreach ($line in Get-Content $config) {
        $clean = ($line -replace '#.*$','').Trim()
        if (-not $clean) { continue }
        $parts = $clean -split '\s+'
        if ($parts[0] -eq 'raw_resources') { $raw = $parts[1]; continue }
        if ($parts.Count -ne 2) {
            return [pscustomobject]@{ Ok=$false; Detail="invalid line: $line" }
        }
        $actual += $parts[0]
    }
    $missing = @($expected | Where-Object { $_ -notin $actual })
    $extra = @($actual | Where-Object { $_ -notin $expected })
    $duplicate = @($actual | Group-Object | Where-Object Count -gt 1)
    $ok = -not $missing -and -not $extra -and -not $duplicate -and
          $actual.Count -le 16 -and $raw -match '^\d+$'
    $detail = if ($ok) {
        "$($actual.Count) UI commodities; raw_resources=$raw; manifest matched"
    } else {
        "missing=$($missing -join ',') extra=$($extra -join ',') duplicates=$($duplicate.Name -join ',') raw=$raw"
    }
    return [pscustomobject]@{ Ok=$ok; Detail=$detail }
}

function Invoke-Doctor {
    $script:EseDoctorBad = 0
    function Check([string]$Label, [string]$State, [string]$Detail) {
        $colour = if ($State -eq 'PASS') { 'Green' } elseif ($State -eq 'WARN') { 'Yellow' } else { 'Red' }
        Write-Host ("[{0}] {1,-18} {2}" -f $State, $Label, $Detail) -ForegroundColor $colour
        if ($State -eq 'FAIL') { $script:EseDoctorBad++ }
    }

    Check 'Empire install' 'PASS' $E.GameDir
    $artifact = Join-Path $E.EseDir 'dinput8.dll'
    if (Test-EseDll $artifact) { Check 'Toolkit DLL' 'PASS' $artifact }
    else { Check 'Toolkit DLL' 'FAIL' 'missing or invalid; install will try to build it' }

    if (-not (Test-Path $E.Dll)) { Check 'Installed DLL' 'FAIL' 'missing; run install' }
    elseif (-not (Test-EseDll $E.Dll)) { Check 'Installed DLL' 'FAIL' 'dinput8.dll belongs to something else' }
    elseif ((Get-FileHash $artifact -Algorithm SHA256).Hash -ne (Get-FileHash $E.Dll -Algorithm SHA256).Hash) {
        Check 'Installed DLL' 'WARN' 'ESE is installed but differs from this toolkit; run install to update'
    } else { Check 'Installed DLL' 'PASS' 'current and hash verified' }

    $checks = @(
        @((Join-Path $E.KitDir 'lua\ese_autoexec.lua'), (Join-Path $E.GameDir 'ese_autoexec.lua'), 'Campaign loader'),
        @((Join-Path $E.KitDir 'lua\fp\ese_battle_autoexec.lua'), (Join-Path $E.GameDir 'ese_battle_autoexec.lua'), 'Battle loader'),
        @((Join-Path $E.KitDir 'lua\ese_core.lua'), (Join-Path $E.GameKitDir 'lua\ese_core.lua'), 'Shared runtime'),
        @((Join-Path $E.KitDir 'lua\ese_mods.lua'), (Join-Path $E.GameKitDir 'lua\ese_mods.lua'), 'Mod list'),
        @((Join-Path $E.KitDir 'config\ese_commodities.txt'), (Join-Path $E.GameDir 'ese_commodities.txt'), 'Trade UI config'),
        @((Join-Path $E.KitDir 'empire_paths.ps1'), (Join-Path $E.GameKitDir 'empire_paths.ps1'), 'PowerShell paths'),
        @((Join-Path $E.KitDir 'empire_paths.rb'), (Join-Path $E.GameKitDir 'empire_paths.rb'), 'Ruby paths')
    )
    foreach ($c in $checks) {
        $state = Test-MirrorFile $c[0] $c[1]
        if ($state -eq 'ok') { Check $c[2] 'PASS' 'synchronized' }
        else { Check $c[2] 'FAIL' "$state; run install or sync" }
    }
    $commodity = Test-CommodityConfig
    Check 'Trade config data' $(if ($commodity.Ok) { 'PASS' } else { 'FAIL' }) $commodity.Detail

    foreach ($mod in Get-EseMods) {
        $state = Get-MirrorTreeStatus (Join-Path $E.KitDir "lua\$($mod.Path)") (Join-Path $E.GameKitDir "lua\$($mod.Path)")
        Check "Lua: $($mod.Id)" $(if ($state.Ok) { 'PASS' } else { 'FAIL' }) $state.Detail
    }
    foreach ($name in @('behavior','db','engine','game','mesh','pack','texture','trademod','ui')) {
        $state = Get-MirrorTreeStatus (Join-Path $E.KitDir "tools\$name") (Join-Path $E.GameKitDir "tools\$name")
        Check "Tool: $name" $(if ($state.Ok) { 'PASS' } else { 'FAIL' }) $state.Detail
    }
    $docsState = Get-MirrorTreeStatus (Join-Path $E.KitDir 'docs') (Join-Path $E.GameKitDir 'docs')
    Check 'Documentation' $(if ($docsState.Ok) { 'PASS' } else { 'FAIL' }) $docsState.Detail

    $p = Get-Process Empire -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        $native = & (Join-Path $E.EseDir 'ese.ps1') -Native 'states' 2>&1 | Select-Object -Last 1
        if ($native -match 'present_hooked=yes') { Check 'Running game' 'PASS' "ESE connected; $native" }
        else { Check 'Running game' 'WARN' "Empire is running, but ESE did not answer normally: $native" }
    } else { Check 'Running game' 'WARN' 'not running; launch after installation' }

    Write-Host ''
    if ($script:EseDoctorBad -gt 0) {
        Write-Host "$script:EseDoctorBad required check(s) failed." -ForegroundColor Red
        return $false
    }
    Write-Host 'ESE is ready.' -ForegroundColor Green
    return $true
}

function Start-EmpireFrontend {
    if (Get-Process Empire -ErrorAction SilentlyContinue) {
        throw "Empire is already running."
    }
    $prefs = $E.Prefs
    if (-not (Test-Path -LiteralPath $prefs)) { throw "preferences not found: $prefs" }
    $lines = [IO.File]::ReadAllLines($prefs, [Text.Encoding]::Unicode)
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*game_startup_mode\b') {
            $found = $true
            'game_startup_mode frontend;'
        } else {
            $line
        }
    }
    if (-not $found) { $out = @($out) + 'game_startup_mode frontend;' }
    [IO.File]::WriteAllLines($prefs, $out, (New-Object Text.UnicodeEncoding($false, $true)))
    $check = [IO.File]::ReadAllBytes($prefs)
    if ($check[0] -ne 0xFF -or $check[1] -ne 0xFE) { throw "BOM lost - Empire would ignore this file. Aborting." }
    "set: game_startup_mode frontend;"
    "launching $($E.Exe) ..."
    Start-Process -FilePath $E.Exe -WorkingDirectory $E.GameDir
}

switch ($Command.ToLower()) {

    'paths' { & (Join-Path $PSScriptRoot 'empire_paths.ps1') }

    'status' {
        $p = Get-Process Empire -ErrorAction SilentlyContinue
        "game          : " + $(if ($p) { "RUNNING pid $($p.Id), $([math]::Round($p.WorkingSet64/1MB)) MB" } else { "not running" })
        "install       : $($E.GameDir)"
        $dll = Get-Item $E.Dll -ErrorAction SilentlyContinue
        "dinput8.dll   : " + $(if ($dll) {
            $owner = if (Test-EseDll $dll.FullName) { 'ESE' } else { 'unknown owner' }
            "{0:N0} bytes, {1}, {2}" -f $dll.Length, $dll.LastWriteTime, $owner
        } else { "MISSING" })
        ""
        "mod packs deployed:"
        Get-ChildItem (Join-Path $E.DataDir 'zz_*.pack') -ErrorAction SilentlyContinue |
            ForEach-Object { "  {0,-24} {1,10:N1} MB" -f $_.Name, ($_.Length / 1MB) }
        if ($p) {
            ""
            $r = & (Join-Path $EseDir 'ese.ps1') -Native 'states' 2>&1 | Select-Object -Last 1
            "ESE runtime   : $r"
            $campaign = & (Join-Path $EseDir 'ese.ps1') 'return type(ESE_RuntimeStatus)=="function" and ESE_RuntimeStatus() or "core unavailable"' 2>&1 | Select-Object -Last 1
            "ESE campaign  : $campaign"
            if ($r -match 'battle=(?!00000000)') {
                $b = & (Join-Path $EseDir 'ese.ps1') -Battle 'return type(ESE_RuntimeStatus)=="function" and ESE_RuntimeStatus() or "core unavailable"' 2>&1 | Select-Object -Last 1
                "ESE battle    : $b"
            }
        }
    }

    'build'  { & (Join-Path $EseDir 'build.ps1') }

    'install' { Install-Ese }
    'update'  { Install-Ese }
    'uninstall' { Uninstall-Ese }
    'doctor' {
        $healthy = Invoke-Doctor
        if (-not $healthy) { exit 1 }
    }
    'release' {
        $releaseArgs = @{}
        if ($Arg1) { $releaseArgs.OutputPath = $Arg1 }
        & (Join-Path $E.KitDir 'release.ps1') @releaseArgs
    }

    'mods' {
        Get-EseMods | Select-Object Id, @{Name='State';Expression={if ($_.Enabled) {'enabled'} else {'disabled'}}}, Path |
            Format-Table -AutoSize
        Write-Host 'Activation changes apply when the next campaign or battle Lua state is created.'
    }
    'enable'  { Set-EseModState $Arg1 $true }
    'disable' { Set-EseModState $Arg1 $false }

    'deploy' {
        Assert-GameClosed
        & (Join-Path $EseDir 'build.ps1') -Deploy
        $a = (Get-FileHash (Join-Path $EseDir 'dinput8.dll') -Algorithm SHA256).Hash
        $b = (Get-FileHash $E.Dll -Algorithm SHA256).Hash
        if ($a -ne $b) { throw "DLL deploy verification FAILED" }
        "DLL hash verified"
    }

    'pack' {
        if (-not $Arg1 -or -not $Arg2) { throw "usage: empire.ps1 pack <stagedir> <name.pack> [-Deploy]" }
        $out = Join-Path $env:TEMP $Arg2
        & ruby (Join-Path $ScriptTools 'pack\build_pack_stream.rb') $Arg1 $out
        if ($Deploy) { Install-Pack $out $Arg2 } else { "built $out  (pass -Deploy to install)" }
    }

    'hipoly' {
        $a = @((Join-Path $ScriptTools 'mesh\hipoly_build.rb'))
        if ($Only) { $a += @('--only', $Only) }
        & ruby @a
        $stage = Join-Path $E.KitDir 'staged\hipoly_auto'
        if ($Deploy) {
            $out = Join-Path $env:TEMP 'zz_hipoly.pack'
            & ruby (Join-Path $ScriptTools 'pack\build_pack_stream.rb') $stage $out
            Install-Pack $out 'zz_hipoly.pack'
        } else {
            "staged only. To install:  .\empire.ps1 pack `"$stage`" zz_hipoly.pack -Deploy"
        }
    }

    'lod' {
        $factor = if ($Arg1) { $Arg1 } else { '3.0' }
        $sp = Join-Path $env:TEMP 'lodstage'
        $d  = Join-Path $sp 'db\warscape_rigid_lod_range_tables'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        & ruby (Join-Path $ScriptTools 'engine\lodscale.rb') $factor `
            (Join-Path $ScriptTools 'engine\lod_range.bin') (Join-Path $d 'warscape_rigid_lod_range')
        $out = Join-Path $env:TEMP 'zz_lod.pack'
        & ruby (Join-Path $ScriptTools 'pack\build_pack_stream.rb') $sp $out
        if ($Deploy) { Install-Pack $out 'zz_lod.pack' } else { "built $out" }
    }

    'sync'    { Sync-GameFiles }
    'launch'  {
        if (-not (Test-EseDll $E.Dll)) {
            throw 'ESE is not installed. Run .\empire.ps1 install first.'
        }
        Sync-GameFiles
        if ($Arg1) {
            & (Join-Path $EseDir 'launch_battle.ps1') -Battle $Arg1
        } else {
            Start-EmpireFrontend
        }
    }
    'restore' { & (Join-Path $EseDir 'launch_battle.ps1') -Restore }

    'arm' {
        $ese = Join-Path $EseDir 'ese.ps1'
        $sc  = Join-Path $E.KitDir 'lua\fp'
        if (-not (Test-Path $sc)) { throw "first-person scripts not found at $sc" }
        foreach ($f in @('fpsetup', 'fppick', 'fpdrive', 'fpctl')) {
            $src = Get-Content (Join-Path $sc "$f`_oneline.lua") -Raw
            & $ese "@battle $src" | Select-Object -Last 1
        }
        & $ese '@battle return ESE.on_tick("fp.main",function() FPHOT() FPMOVE() FPSTEP() FPCTL() end,100)' | Select-Object -Last 1
    }

    'shot' {
        $name = if ($Arg1) { $Arg1 } else { 'shot.png' }
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $vs = [Windows.Forms.SystemInformation]::VirtualScreen
        $b = [Drawing.Bitmap]::new($vs.Width, $vs.Height)
        $g = [Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($vs.Location, [Drawing.Point]::Empty, $b.Size)
        $p = Join-Path (Get-Location) $name
        $b.Save($p, [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
        "saved $p"
    }

    default {
        # Get-Help renders only the syntax line here, which is useless, so print
        # the usage directly.
        @"
empire.ps1 - one entry point for every routine Empire modding workflow.
Paths resolve dynamically, so this works on any machine (override: EMPIRE_DIR).

  install                    install or repair from the prebuilt DLL; sync Lua/tools
  doctor                     read-only setup check with exact repair guidance
  update                     same safe, idempotent operation as install
  uninstall                  disable ESE; restore an existing proxy backup if present
  release [output.zip]       build a clean release containing no generated packs
  mods                       list mods and their activation state
  enable <id>                enable a mod for the next state load
  disable <id>               disable a mod for the next state load
  paths                      show the resolved install
  status                     what is deployed, is the game up, is ESE alive
  launch [battle.xml]        sync and start Empire; requires install first
  build                      developer: build the ESE proxy DLL
  deploy                     developer: build + deploy the DLL (hash verified)
  pack <stagedir> <name>     build a .pack from a staged tree   [-Deploy]
  sync                       create Lua and Tools under the install and copy
                             the files the game and the helpers read
  hipoly                     extract + subdivide + stage the unit corpus
                               -Only <substr>   limit to matching units
                               -Deploy          also pack and install
  lod <factor>               rebuild the LOD distance-band pack [-Deploy]
  arm                        install the first-person rig into a live battle
  shot [name.png]            screenshot
  restore                    undo the launch preference edit

Examples
  .\empire.ps1 install
  .\empire.ps1 mods
  .\empire.ps1 enable fp
  .\empire.ps1 doctor
  .\empire.ps1 launch
  .\empire.ps1 status
  .\empire.ps1 hipoly -Only euro_line -Deploy
  .\empire.ps1 pack .\stage zz_mymod.pack -Deploy

Start with INDEX.md, then docs/REVIEW_SECURITY_AND_MODDING.md.
"@ | Write-Host
    }
}
