-- TRUE first person: drive the SOLDIER, not his regiment.
-- Writing a live man's position vec3 at +0x48 holds - the engine does not snap
-- him back - so WASD can move the man himself and the camera follows as usual.
-- Y is rewritten every step from the heightfield so he walks up and down slopes
-- instead of sinking or floating, and his mount lift is preserved.
FPDRIVE  = false   -- master switch for personal movement
FPSPEED  = FPSPEED  or 2.2    -- m/s walking
FPRUNSPD = FPRUNSPD or 5.0    -- m/s with shift
FPVY     = 0                  -- vertical velocity (jump)
FPJUMPH  = 0                  -- current height above his footing
FPJUMPV0 = FPJUMPV0 or 4.2    -- jump launch speed
FPGRAV   = FPGRAV   or 11.0
FPMOVED  = 0
FPSPACEPREV = false

function FPMOVE()
  if not FPDRIVE then return end
  local aa,P = FPAA,FPP
  -- The man we write is an index into the cached entity array. A rebuilt
  -- manager means that index is someone else, or nothing.
  if FPFRESH and not FPFRESH() then return end
  if FPFRIENDLY and not FPFRIENDLY() then return end   -- never puppet an enemy
  local u = P(aa(FPD, FPI*4)); if not u then return end
  local x = tonumber(ESE_ReadFloat(aa(u,0x48)))
  local y = tonumber(ESE_ReadFloat(aa(u,0x4C)))
  local z = tonumber(ESE_ReadFloat(aa(u,0x50)))
  if not x or not y or not z or x~=x then return end
  if math.abs(x) > 1020 or math.abs(z) > 1020 then return end
  local dt = 0.016
  -- preserve mount height: lift is 1.0 mounted, 0 on foot
  local lift = y - FPGROUND(x,z) - (FPJUMPH or 0)
  if lift < 0.2 then lift = 0 elseif lift > 0.2 then lift = 1.0 end

  local yr = FPYAW*math.pi/180
  local fx, fz = math.sin(yr), math.cos(yr)
  local rx, rz = fz, -fx          -- right = forward rotated -90 deg
  local mx, mz = 0, 0
  if ESE_Input("11") == "1" then mx = mx + fx; mz = mz + fz end   -- W
  if ESE_Input("1F") == "1" then mx = mx - fx; mz = mz - fz end   -- S
  if ESE_Input("1E") == "1" then mx = mx - rx; mz = mz - rz end   -- A strafe
  if ESE_Input("20") == "1" then mx = mx + rx; mz = mz + rz end   -- D strafe
  local spd = (ESE_Input("2A") == "1") and FPRUNSPD or FPSPEED

  local nx, nz = x, z
  local L = math.sqrt(mx*mx + mz*mz)
  if L > 0.001 then
    nx = x + (mx/L)*spd*dt
    nz = z + (mz/L)*spd*dt
    if nx < -1020 then nx = -1020 elseif nx > 1020 then nx = 1020 end
    if nz < -1020 then nz = -1020 elseif nz > 1020 then nz = 1020 end
    FPMOVED = FPMOVED + 1
  end

  -- jump: a real ballistic arc. Empire has no jump animation, so he rises and
  -- falls without leaving the ground pose - the motion is real, the pose is not.
  local sp = (ESE_Input("39") == "1")
  if sp and not FPSPACEPREV and (FPJUMPH or 0) <= 0.001 then FPVY = FPJUMPV0 end
  FPSPACEPREV = sp
  if FPVY ~= 0 or (FPJUMPH or 0) > 0 then
    FPVY = FPVY - FPGRAV*dt
    FPJUMPH = (FPJUMPH or 0) + FPVY*dt
    if FPJUMPH <= 0 then FPJUMPH = 0; FPVY = 0 end
  end

  ESE_WriteFloat(aa(u,0x48), nx)
  ESE_WriteFloat(aa(u,0x50), nz)
  ESE_WriteFloat(aa(u,0x4C), FPGROUND(nx,nz) + lift + (FPJUMPH or 0))
end
return "drive loaded (set FPDRIVE=true; WASD moves the MAN, space jumps)"
