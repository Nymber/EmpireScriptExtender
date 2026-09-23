-- Find what makes a man move. Snapshot ONE living soldier repeatedly:
--   slots 'still1','still2' while his unit is HALTED  -> the noise control
--   slot  'walk'            while his unit is MARCHING
-- Report fields that differ between still2 and walk but were stable across the
-- two still samples. Those are the movement/steering state.
WD = WD or {}
function WDSNAP(slot, idx)
  local aa,P = FPAA,FPP
  local i = idx or FPI
  local e = P(aa(FPD, i*4)); if not e then return "no entity "..i end
  local u = P(aa(e,0x1EC))
  if not u or #u < 6 or (tonumber(ESE_ReadInt(aa(u,0x178))) or 0) <= 0 then
    return "man "..i.." is in a unit with 0 strength - pick another"
  end
  local t = {__i=i, __e=e}
  for off=0,0x400,4 do t[off] = P(aa(e,off)) end
  local x=tonumber(ESE_ReadFloat(aa(e,0x48)))
  local z=tonumber(ESE_ReadFloat(aa(e,0x50)))
  t.__x, t.__z = x, z
  WD[slot] = t
  return string.format("snap '%s' man %d at (%.2f,%.2f)", slot, i, x, z)
end
function WDDIFF()
  local aa = FPAA
  local a,b,c = WD.still1, WD.still2, WD.walk
  if not (a and b and c) then return "need still1, still2, walk" end
  if a.__e ~= c.__e then return "different entity between snapshots" end
  local moved = math.sqrt((c.__x-b.__x)^2 + (c.__z-b.__z)^2)
  local out = {string.format("man %d moved %.2f m between the still and walking samples", c.__i, moved)}
  for off=0,0x400,4 do
    if b[off] ~= c[off] and a[off] == b[off] then
      local fb = ESE_ReadFloat(aa(c.__e, off))
      out[#out+1] = string.format("+%X  %s -> %s   (now float %s)", off, b[off], c[off], tostring(fb))
    end
  end
  if #out == 1 then out[#out+1] = "nothing changed beyond the control" end
  return table.concat(out, "\n")
end
return "walkdiff loaded: WDSNAP('still1') WDSNAP('still2') WDSNAP('walk') WDDIFF()"
