-- Common battle entry. Empire creates a fresh Lua state for every battle.
local root = os.getenv('ESE_MODS_DIR')
if not root or root == '' then root = os.getenv('ESE_CHAIN_DIR') end
if not root or root == '' then root = [[EmpireScriptExtender\lua\]] end
root = root:gsub('/', '\\'); if root:sub(-1) ~= '\\' then root = root .. '\\' end

local core, err = loadfile(root .. 'ese_core.lua')
if not core then
  if type(ESE_Log)=='function' then ESE_Log('[core] battle bootstrap failed: '..tostring(err)) end
  return
end
local ok, runtime = pcall(core)
if not ok or type(runtime) ~= 'table' then
  if type(ESE_Log)=='function' then ESE_Log('[core] battle runtime failed: '..tostring(runtime)) end
  return
end
runtime.load_configured_mods('battle')
