-- Liveness. Verified against ground truth: counting entity+0x348==1 across the
-- player's army gave exactly 8, matching the sum of unit+0x178 (current
-- strength) when only one 8-man artillery unit remained alive.
--   entity+0x348 == 1   -> this man is alive
--   unit+0x178         -> unit's CURRENT strength (0 = wiped/routed away)
--   unit+0x18C         -> unit's MAX strength (do not use for survivors)
-- Corpses stay lying on the field and keep normal-looking state in +0x34/+0x38
-- and +0xF0, so those are NOT liveness - they fooled an earlier attempt.
function FPALIVE(i)
  local aa,P = FPAA,FPP
  local e = P(aa(FPD, (i or FPI)*4)); if not e then return false end
  return P(aa(e, 0x348)) == "00000001"
end
function FPUNITALIVE(i)
  local aa,P = FPAA,FPP
  local e = P(aa(FPD, (i or FPI)*4)); if not e then return 0 end
  local u = P(aa(e, 0x1EC)); if not u or u == "00000000" then return 0 end
  return tonumber(ESE_ReadInt(aa(u, 0x178))) or 0
end

-- FPPICK(): hook whichever soldier is nearest the centre of the screen.
-- Uses the camera's own eye (+0x08) and forward (+0x60): for each entity, take
-- the angle between "camera -> man" and the forward vector, and keep the
-- smallest. No unprojection and no new native needed - the crosshair IS the ray.
function FPPICK(apply)
  local aa,P = FPAA,FPP
  local ex=tonumber(ESE_ReadFloat(aa(FPCAM,0x08)))
  local ey=tonumber(ESE_ReadFloat(aa(FPCAM,0x0C)))
  local ez=tonumber(ESE_ReadFloat(aa(FPCAM,0x10)))
  local fx=tonumber(ESE_ReadFloat(aa(FPCAM,0x60)))
  local fy=tonumber(ESE_ReadFloat(aa(FPCAM,0x64)))
  local fz=tonumber(ESE_ReadFloat(aa(FPCAM,0x68)))
  if not ex or not fx then return "no camera" end
  local best,bang,bd,bu = nil,1e9,0,nil
  for i=0,FPCNT-1 do
    local e=P(aa(FPD,i*4))
    if e then
      local x=tonumber(ESE_ReadFloat(aa(e,0x48)))
      local y=tonumber(ESE_ReadFloat(aa(e,0x4C)))
      local z=tonumber(ESE_ReadFloat(aa(e,0x50)))
      local liveok = (P(aa(e,0x348)) == "00000001") or FPPICKDEAD
      if liveok and x and y and z and x==x and math.abs(x)<2000 then
        local dx,dy,dz = x-ex, (y+0.9)-ey, z-ez     -- aim at chest, not feet
        local d=math.sqrt(dx*dx+dy*dy+dz*dz)
        if d>0.5 then
          local dot=(dx*fx+dy*fy+dz*fz)/d
          if dot>0 then
            local ang=math.acos(math.min(dot,1))
            -- prefer the CLOSEST man along a near-centre ray, not merely the
            -- most centred one: a distant soldier can line up behind a near one
            local score=ang + d*0.0004
            if score<bang then bang=score best=i bd=d bu=P(aa(e,0x1EC)) end
          end
        end
      end
    end
  end
  if not best then return "nothing in front of the camera" end
  if apply then FPI=best for k=1,20 do FPSTEP() end end
  return string.format("nearest LIVING man to crosshair: %d  dist=%.1f m  unit=%s%s",
    best, bd, tostring(bu), apply and "  -> HOOKED" or "")
end
return "FPPICK loaded"
