-- Thin battle entry. ESE runs this from the game root when it acquires a
-- battle state (Empire rebuilds that state per battle and wipes globals).
--
-- The rig itself is the fp folder, same shape as a campaign mod: listed in
-- ese_mods.lua, loaded from mod.lua. This file only marks the state as a
-- battle and loads that folder. A campaign pass of the same mod.lua sees
-- ESE.battle unset and returns.
--
-- Long brackets, not quotes: Lua 5.1 drops unknown backslash escapes, so a
-- quoted Windows path compiles and then points at the wrong file. Relative
-- loadfile resolves against the process cwd, which for Empire is the install.

ESE = ESE or {}
ESE.battle = true

local function blog(s)
  if type(ESE_Log) == 'function' then ESE_Log('[fp] ' .. tostring(s)) end
end

local root = os.getenv('ESE_MODS_DIR')
if not root or root == '' then root = os.getenv('ESE_CHAIN_DIR') end
if root and root ~= '' then
  root = root:gsub('/', '\\')
  if root:sub(-1) ~= '\\' then root = root .. '\\' end
else
  root = [[EmpireScriptExtender\lua\]]
end

local list, lerr = loadfile(root .. 'ese_mods.lua')
if not list then
  blog('no ese_mods.lua in ' .. root .. ' (' .. tostring(lerr) .. ')')
  return
end
local ok, mods = pcall(list)
if not ok or type(mods) ~= 'table' then
  blog('ese_mods.lua did not return a table - ' .. tostring(mods))
  return
end

local enabled = false
for _, name in ipairs(mods) do
  if name == 'fp' then enabled = true break end
end
if not enabled then
  blog('fp is not listed in ese_mods.lua - rig not installed')
  return
end

local dir = root .. [[fp\]]
ESE.mod_dir = dir
local f, ferr = loadfile(dir .. 'mod.lua')
if not f then
  ESE.mod_dir = nil
  blog('fp/mod.lua did not load - ' .. tostring(ferr))
  return
end
local mok, err = pcall(f)
ESE.mod_dir = nil
if not mok then blog('fp/mod.lua FAILED - ' .. tostring(err)) end