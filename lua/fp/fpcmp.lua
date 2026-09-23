-- Compare the camera with the units under it. Read only. Call FPCMP() from
-- the pipe; it is not on the tick.
--
-- The object at manager+0x28048 is not the selected troop. Live read during
-- deployment: vtable, then a flag, then zeros. No count, no pointer array,
-- and it does not move when the camera does. The troop is the entity cluster
-- whose centre is nearest the camera's ground point.
--
-- A man's Y is terrain height (about 196 here). The RTS camera sits a few
-- metres above that, so a "Y under 40" filter matches nobody. The camera
-- marker itself is an entity at the camera's own X/Z with a unit pointer, so
-- an exact-position match is also wrong. Rank by horizontal distance and
-- keep groups of at least 8 men.

function FPCMP()
  local aa, P = FPAA, FPP
  if not FPCAM or not FPD then
    local ok, why = FPSYNC()
    if not ok then return "no battle: " .. tostring(why) end
  end
  local cx = tonumber(ESE_ReadFloat(aa(FPCAM, 0x08)))
  local cy = tonumber(ESE_ReadFloat(aa(FPCAM, 0x0C)))
  local cz = tonumber(ESE_ReadFloat(aa(FPCAM, 0x10)))
  if not cx or not cz then return "camera unreadable" end

  local groups = {}
  local n = FPCNT or 0
  if n > 2000 then n = 2000 end
  for i = 0, n - 1 do
    local e = P(aa(FPD, i * 4))
    if e then
      local y = tonumber(ESE_ReadFloat(aa(e, 0x4C)))
      if y and y > 100 and y < 260 then
        local u = P(aa(e, 0x1EC))
        if u and #u >= 6 and u ~= "00000000" then
          local g = groups[u]
          if not g then
            g = { n = 0, sx = 0, sz = 0, best = 1e18, bi = i, by = y }
            groups[u] = g
          end
          local x = tonumber(ESE_ReadFloat(aa(e, 0x48))) or 0
          local z = tonumber(ESE_ReadFloat(aa(e, 0x50))) or 0
          local dx, dz = x - cx, z - cz
          local d = dx * dx + dz * dz
          -- The camera itself is an entity, sitting on the camera X/Z with a
          -- unit pointer. Counting it makes "nearest man" a 0 m false hit.
          if d < 4 then
            g.skip = (g.skip or 0) + 1
          else
            g.n = g.n + 1
            g.sx = g.sx + x
            g.sz = g.sz + z
            if d < g.best then g.best = d g.bi = i g.by = y end
          end
        end
      end
    end
  end

  local list = {}
  for u, g in pairs(groups) do
    if g.n >= 8 then
      list[#list + 1] = {
        u = u, n = g.n, d = math.sqrt(g.best),
        ax = g.sx / g.n, az = g.sz / g.n, i = g.bi, y = g.by,
      }
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  if #list == 0 then
    return string.format("cam %.0f %.0f %.0f  no unit cluster under it", cx, cy, cz)
  end

  local g = list[1]
  local st = tonumber(ESE_ReadInt(aa(g.u, 0x178))) or -1
  FPCMP_UNIT = g.u
  FPCMP_MAN  = g.i
  return string.format(
    "cam %.0f %.0f %.0f  nearest unit %s  men=%d str=%d  centre %.0f %.0f  closest man %d at %.0fm (feet %.0f, camera is %.0fm above)",
    cx, cy, cz, g.u, g.n, st, g.ax, g.az, g.i, g.d, g.y, cy - g.y)
end

-- Record the player army object from a known-friendly unit. At deployment, the
-- default camera starts over the player's line, so `FPCMP(); FPCLAIMARMY()` is
-- the current safest way to seed the team gate before enabling FPCTL/FPDRIVE.
-- This helper is explicit on purpose: automatic claiming from an arbitrary
-- camera position would make enemy control possible after a free-camera move.
function FPCLAIMARMY(unit)
  local aa, P = FPAA, FPP
  local u = unit or FPCMP_UNIT
  if not u then
    FPCMP()
    u = FPCMP_UNIT
  end
  if not u then return "no candidate unit; point the camera over a friendly unit and run FPCMP()" end
  local army = P(aa(u, 0x160))
  if not army or army == "00000000" then return "candidate unit has no army pointer" end
  FPARMY = army
  return "FPARMY=" .. tostring(FPARMY) .. " from unit " .. tostring(u)
end
return "FPCMP loaded"
