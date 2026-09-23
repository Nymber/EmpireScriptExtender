-- spawn.lua - defines ToggleEseUi in a UI lua_State.
--
-- The HUD button ese_ui_spawn calls root:LuaCall("ToggleEseUi"). That
-- reaches this state only if this file has been loaded into it first:
--
--   ese.ps1 -UI "assert(loadfile([[EmpireScriptExtender\lua\ui\spawn.lua]]))()"
--
-- What it toggles is dialogue_box. That is the one panel ESE already opens
-- without faulting. It is not the trade screen. A panel of our own needs
-- its own layout file and a compiled script, which this button does not.
--
-- ClosePanel is not a function this install has been shown to have, so the
-- second click hides the box through the component instead of the manager.

local function manager()
  local ok, pm = pcall(function()
    return require('Utilities').Require('panelmanager')
  end)
  if not ok then return nil end
  return pm
end

function ToggleEseUi()
  local pm = manager()
  if not pm then return end
  if pm.IsPanelOpen('dialogue_box') then
    local root = UIComponent(Component.Root())
    local box = root and root.Find and root:Find('dialogue_box')
    if box then UIComponent(box):SetVisible(false) end
    return
  end
  pm.OpenPanel('dialogue_box', false, 'Initialise', 'UI kit')
end
