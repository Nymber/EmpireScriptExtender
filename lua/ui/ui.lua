-- ui.lua - the in-game half of the UI kit.
--
-- The Ruby files under tools/ui edit a panel's XML before it is packed.
-- They cannot run in the game. This file can: it uses Component and
-- UIComponent, which exist only in a UI lua_State.
--
-- A campaign mod.lua must not call these. That state has no UIComponent,
-- and UIComponent(nil) raises. Load this from a panel script, or from
-- ese.ps1 -UI, after the panel is open:
--
--   local base = [[EmpireScriptExtender\lua\ui\]]
--   local ui = assert(loadfile(base .. 'ui.lua'))()
--   local pane = ui.find(window, 'stock market')
--   ui.text(ui.find(pane, 'stk_rum', 'dy_value'), '12')
--
-- Find is recursive, so a cloned control needs a name the original panel
-- does not use. A missing name returns nil; it does not raise.
--
-- Creating a control at runtime only works from a template the panel
-- already hosts. Supply does this with TradeRouteEntry. Cloning a
-- template the host does not provide faulted dialogue_box (00F4AD23).
-- This file will not invent a component the layout does not already have.

local M = {}

function M.wrap(addr)
  if addr == nil then return nil end
  if type(addr) == 'userdata' or type(addr) == 'table' then
    if type(addr.Id) == 'function' then return addr end
  end
  if type(UIComponent) ~= 'function' then return nil end
  local ok, c = pcall(UIComponent, addr)
  if not ok then return nil end
  return c
end

-- Walk a Find chain. The first miss returns nil instead of raising.
function M.find(root, ...)
  local c = M.wrap(root)
  if not c then return nil end
  for i = 1, select('#', ...) do
    local name = select(i, ...)
    if type(c.Find) ~= 'function' then return nil end
    local ok, addr = pcall(function() return c:Find(name) end)
    if not ok or addr == nil then return nil end
    c = M.wrap(addr)
    if not c then return nil end
  end
  return c
end

function M.text(c, s)
  c = M.wrap(c)
  if not c or type(c.SetStateText) ~= 'function' then return false end
  local ok = pcall(function() c:SetStateText(tostring(s)) end)
  return ok
end

function M.show(c, on)
  c = M.wrap(c)
  if not c or type(c.SetVisible) ~= 'function' then return false end
  local ok = pcall(function() c:SetVisible(on and true or false) end)
  return ok
end

-- Position() returns x, y. MoveTo takes both. Passing one number as x
-- walks the control off the left of the pane.
function M.move(c, x, y)
  c = M.wrap(c)
  if not c or type(c.MoveTo) ~= 'function' then return false end
  local ok = pcall(function() c:MoveTo(x, y) end)
  return ok
end

-- Vanilla scrollbar. overflow is content height minus the window height,
-- not the row span: the row span overscrolls by one row.
-- Notify has to be wired by the panel (SetProperty("Notify", Address));
-- this only sets the range and resets the handle.
function M.scroll_range(slider, content_h, window_h)
  slider = M.wrap(slider)
  if not slider or type(slider.SetProperty) ~= 'function' then return false end
  local overflow = content_h - window_h
  if overflow < 0 then overflow = 0 end
  local ok = pcall(function()
    slider:SetProperty('maxValue', overflow)
    if type(slider.LuaCall) == 'function' then slider:LuaCall('Reset') end
  end)
  return ok
end

function M.scroll_to(child, value, base_y)
  child = M.wrap(child)
  if not child or type(child.Position) ~= 'function' then return false end
  local ok, x = pcall(function()
    local px = child:Position()
    return px
  end)
  if not ok then return false end
  return M.move(child, x, base_y - value)
end

-- Clone a template the host already has, as a child of parent.
-- name must be unique under that parent. Returns the new component, or nil.
function M.from_template(template, name, parent)
  if type(Component) ~= 'table' or type(Component.CreateComponentFromTemplate) ~= 'function' then
    return nil
  end
  parent = M.wrap(parent)
  if not parent or type(parent.Address) ~= 'function' then return nil end
  local ok, addr = pcall(function()
    return Component.CreateComponentFromTemplate(template, name, parent:Address(), 0)
  end)
  if not ok then return nil end
  return M.wrap(addr)
end

-- Fill a list of rows inside a display_window, the way Supply fills
-- trade routes. Existing children are destroyed first, so calling it
-- again replaces the list instead of stacking on it.
-- rows is { { template = 'TradeRouteEntry', name = 'row1', text = '...' }, ... }
function M.fill(window, rows)
  window = M.wrap(window)
  if not window then return 0 end
  if type(window.DestroyChildren) == 'function' then
    pcall(function() window:DestroyChildren() end)
  end
  local n = 0
  for i = 1, #rows do
    local row = rows[i]
    local c = M.from_template(row.template, row.name or ('row' .. i), window)
    if c then
      n = n + 1
      if row.text then M.text(c, row.text) end
      if row.x and row.y then M.move(c, row.x, row.y) end
    end
  end
  return n
end

return M
