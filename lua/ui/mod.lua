-- The manifest restricts this entry to the UI state. ESE does not yet have a
-- general UI-state autoexec, so current panel scripts load ui.lua themselves.

if type(ESE_Log) == 'function' then
  ESE_Log('[ui] skipped - campaign state has no UIComponent')
end
