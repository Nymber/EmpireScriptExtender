-- Selection/order diagnostics for the first-person roadmap.
-- The current blocker is that Current_Selection_* calls only dispatch when the
-- transient battle selection gate at base+0x3C0 is armed. Do not force it: in
-- some battle states the paired context pointer at base+0x3D4 is zero.

function FPSELSTATE()
  local aa,P = FPAA,FPP
  local function hxnum(v)
    return string.format("%08X", tonumber(v) or 0)
  end
  local function b(addr, n)
    return tostring(ESE_ReadBytes(addr, n or 8))
  end
  local base_raw = ESE_ReadInt("s:137D488")
  local base = hxnum(base_raw)
  local e = (FPD and FPI) and P(aa(FPD, FPI*4)) or nil
  local u = e and P(aa(e,0x1EC)) or nil
  local army = u and P(aa(u,0x160)) or nil
  local strength = u and tostring(ESE_ReadInt(aa(u,0x178))) or "nil"
  local friendly = false
  if FPFRIENDLY then friendly = FPFRIENDLY() end
  local out = {
    "base="..base,
    "gate3C0="..b(aa(base,0x3C0),4),
    "ctx3D4="..tostring(ESE_ReadInt(aa(base,0x3D4))).."/"..b(aa(base,0x3D4),8),
    "order3BC="..tostring(ESE_ReadInt(aa(base,0x3BC))).."/"..b(aa(base,0x3BC),8),
    "cleanup3CC="..tostring(ESE_ReadInt(aa(base,0x3CC))).."/"..b(aa(base,0x3CC),8),
    "FPI="..tostring(FPI),
    "entity="..tostring(e),
    "unit="..tostring(u),
    "unitArmy="..tostring(army),
    "FPARMY="..tostring(FPARMY),
    "friendly="..tostring(friendly),
    "strength="..strength,
  }
  return table.concat(out, " | ")
end

return "FPSELSTATE loaded"
