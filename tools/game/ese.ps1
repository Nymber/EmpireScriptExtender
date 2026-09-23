<#
  ese.ps1 - talk to the running game.

  Sends Lua source to ese_proxy.dll over a named pipe; the DLL queues it and a
  hook running on the GAME's own thread evaluates it in the CAMPAIGN SCRIPTING
  STATE, then the result comes back. The game keeps running throughout - this
  exists so we stop restarting it for every experiment.

  Usage:
    .\ese.ps1 "return ESE_Ping()"            # one-shot
    .\ese.ps1 -Repl                          # interactive prompt
    .\ese.ps1 -Probe                         # built-in sanity checks

  Notes:
    - "return <expr>" to get a value back; bare statements return nil.
    - The game must be running WITH a campaign loaded (the campaign state does
      not exist before that, and the DLL will say so).
#>
param(
    [Parameter(Position=0)][string]$Code,
    [switch]$Repl,
    [switch]$Probe,
    # Evaluate in a UI lua_State instead of the campaign one. Empire runs the UI
    # in separate states, and the UI API (UIComponent/Component/panelmanager)
    # exists ONLY there - so anything that draws on screen needs -UI.
    [switch]$UI,
    # Evaluate in the BATTLE lua_State, where Empire's 208-function battle API
    # lives (CameraZoomTo, Current_Selection_*, EnableShortcutHandler, ...).
    # That state is created per battle, so this only works while in one.
    # See docs/LUA_API.md PART 3.
    [switch]$Battle,
    # ESE's own commands, no Lua state required. Works at the main menu, in a
    # custom battle, anywhere the DLL is loaded.
    [switch]$Native,
    # Show a dialogue box in the running game. Routed to the UI state
    # automatically - panelmanager only works there.
    [string]$Say,
    [int]$TimeoutMs = 8000
)

function Send-Ese([string]$lua) {
    # "@ui " routes to the campaign UI state (where the UI API lives)
    if ($UI)     { $lua = "@ui $lua" }
    if ($Battle) { $lua = "@battle $lua" }
    # -Native runs an ESE command that needs NO lua_State at all
    # (@nat states | fps on|off|report | impact ... | mouse click X Y | drag ...).
    # In a custom battle there is no campaign state and the battle state may not
    # be bound yet, which used to make the whole channel unusable.
    if ($Native) { $lua = "@nat $lua" }
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'ese', [System.IO.Pipes.PipeDirection]::InOut)
    try { $pipe.Connect($TimeoutMs) }
    catch {
        return "[no connection] Is the game running with dinput8.dll (ESE) installed? " +
               "Check ese_log.txt in the game folder."
    }
    try {
        $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($lua)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
        $buf = New-Object byte[] 8192
        $n = $pipe.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return "[empty response]" }
        return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } finally { $pipe.Dispose() }
}

if ($Say) {
    # Escape for a Lua single-quoted string, then open the vanilla dialogue_box
    # panel. Always "@ui " - panelmanager needs the UI state's Component API;
    # from the campaign state OpenPanel dies on a nil TriggerPanelOpenEvent.
    $esc = $Say -replace '\\','\\\\' -replace "'","\'" -replace "`r?`n",'\n'
    $lua = "@ui local pm=require('Utilities').Require('panelmanager') " +
           "local ok,err=pcall(pm.OpenPanel,'dialogue_box',false,'Initialise','$esc') " +
           "return ok and 'shown' or ('failed: '..tostring(err))"
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'ese', [System.IO.Pipes.PipeDirection]::InOut)
    try { $pipe.Connect($TimeoutMs) } catch { Write-Output "[no connection] is the game running?"; return }
    try {
        $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
        $b = [System.Text.Encoding]::ASCII.GetBytes($lua)
        $pipe.Write($b, 0, $b.Length); $pipe.Flush()
        $buf = New-Object byte[] 8192
        $n = $pipe.Read($buf, 0, $buf.Length)
        Write-Output ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
    } finally { $pipe.Dispose() }
    return
}

if ($Probe) {
    $checks = @(
        @{ q = "return ESE_Version()";                    why = "DLL native fn reachable" },
        @{ q = "return ESE_Ping()";                       why = "native call round-trip" },
        @{ q = "return type(conditions)";                 why = "campaign API present (expect table)" },
        @{ q = "return type(effect)";                     why = "campaign API present (expect table)" },
        @{ q = "return tostring(rawget(_G,'ESE_Ping'))";  why = "_G is NOT the campaign globals (expect nil)" },
        @{ q = "return _VERSION";                         why = "Lua version (expect Lua 5.1)" }
    )
    foreach ($c in $checks) {
        $r = Send-Ese $c.q
        Write-Output ("{0,-46} -> {1}" -f $c.q, $r)
        Write-Output ("{0,-46}    ({1})" -f "", $c.why)
    }
    return
}

if ($Repl) {
    Write-Host "ESE Lua REPL - evaluates in Empire's campaign scripting state."
    Write-Host "Type Lua, 'quit' to exit. Use 'return x' to see a value."
    Write-Host ""
    while ($true) {
        Write-Host -NoNewline "lua> "
        $line = Read-Host
        if ($null -eq $line) { break }
        if ($line -in @('quit','exit')) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # convenience: a bare expression is almost always meant as "return <it>"
        if ($line -notmatch '^\s*(return|local|if|for|while|do|function|--)') {
            if ($line -notmatch '[=;]') { $line = "return $line" }
        }
        Write-Host (Send-Ese $line)
    }
    return
}

# single-quoted: PowerShell does NOT accept C-style \" escaping inside a
# double-quoted string (use a backtick, or single quotes as here)
if (-not $Code) { Write-Host 'usage: .\ese.ps1 "return ESE_Ping()"  |  -Repl  |  -Probe'; exit 1 }
# Write-OUTPUT, not Write-Host: results must flow down the pipeline so callers
# can capture them ($x = .\ese.ps1 "..."). Write-Host goes straight to the
# console and returns $null to the caller, which silently broke scripted use.
Write-Output (Send-Ese $Code)
