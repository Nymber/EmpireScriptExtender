-- First-person battle rig. Listed in ese_mods.lua like any other folder.
--
-- The campaign loader and the battle autoexec both reach this file. They are
-- different lua_States. Camera reads and ESE_Tick belong only in the battle
-- one, so a campaign pass logs and returns. The game-root
-- ese_battle_autoexec.lua sets ESE.battle before loading this file.
--
-- ESE.mod_dir is this folder, trailing backslash, when a loader set it.
-- Long brackets, not quotes: Lua 5.1 drops unknown backslash escapes.

if not (ESE and ESE.battle) then
  if type(ESE_Log) == 'function' then
    ESE_Log('[fp] skipped - not a battle state')
  end
  return
end

local base = ESE.mod_dir or [[EmpireScriptExtender\lua\fp\]]

local function flog(s)
  if type(ESE_Log) == 'function' then ESE_Log('[fp] ' .. tostring(s)) end
end

-- Do not strip `return` from the part files. Several are multi-line, and
-- dropping only the first line leaves an orphaned continuation. pcall makes
-- a top-level return leave the wrapper instead of this chunk.
local parts = { 'fpsetup.lua', 'fppick.lua', 'fpdrive.lua', 'walkdiff.lua', 'fpctl.lua', 'fpcmp.lua' }
local failed = 0
for _, name in ipairs(parts) do
  local f, ferr = loadfile(base .. name)
  if not f then
    failed = failed + 1
    flog(name .. ' did not load - ' .. tostring(ferr))
  else
    local ok, err = pcall(f)
    if not ok then
      failed = failed + 1
      flog(name .. ' FAILED - ' .. tostring(err))
    end
  end
end

if type(ESE_Tick) == 'function' then
  ESE_Tick('ms', '16')
  ESE_Tick('on', 'FPHOT() FPMOVE() FPSTEP() FPCTL()')
end
FPCTLON = false
FPDRIVE = false
flog('rig installed, FPSTEP=' .. type(FPSTEP) .. ' failed=' .. failed)
