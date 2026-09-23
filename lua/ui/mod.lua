-- The in-game UI kit is not a campaign mod. Listing this folder still
-- loads it, because the campaign loader loads every name in ese_mods.lua.
-- Component and UIComponent do not exist here, so installing anything
-- would raise. A panel script loads ui.lua itself.

if type(ESE_Log) == 'function' then
  ESE_Log('[ui] skipped - campaign state has no UIComponent')
end
