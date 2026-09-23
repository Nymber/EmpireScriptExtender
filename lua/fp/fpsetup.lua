-- First-person rig: address derivation + per-frame follower.
-- Everything is re-derivable at runtime: Empire rebuilds the battle manager at
-- the deployment -> battle transition, which silently invalidated the entity
-- array and the camera last time. FPSTEP now notices and re-syncs itself.
function FPAA(h,o)
  local n=#h local hi=tonumber(h:sub(1,n-4),16) local lo=tonumber(h:sub(n-3),16)
  local ohi=math.floor(o/65536) hi=hi+ohi lo=lo+(o-ohi*65536)
  while lo>=65536 do lo=lo-65536 hi=hi+1 end while lo<0 do lo=lo+65536 hi=hi-1 end
  return string.format("%X%04X",hi,lo)
end
function FPP(a)
  local s=ESE_ReadBytes(a,"#4") if s=="UNREADABLE" then return nil end
  local b={} for h in s:gmatch("%x%x") do b[#b+1]=h end
  if #b<4 then return nil end return b[4]..b[3]..b[2]..b[1]
end
-- The battle manager is rebuilt at the deployment to battle transition. The
-- static root stays. The pointer at +0x31C does not. A cached camera written
-- after that change is a null read in the renderer.
function FPLIVE()
  local base = FPP("s:137D488")
  if not base then return nil end
  return FPP(FPAA(base, 0x31C))
end
-- True only while the cached camera still belongs to the live manager.
-- A mismatch drops the cache before any write can use it.
function FPFRESH()
  local live = FPLIVE()
  if live and live == FPMGR and FPCAM then return true end
  if live ~= FPSEEN then
    if ESE_Log then
      ESE_Log("[fp] manager " .. tostring(FPSEEN) .. " -> " .. tostring(live))
    end
    FPSEEN = live
  end
  FPCAM, FPD, FPDATA, FPMGR = nil, nil, nil, nil
  FPCTLON = false
  return false
end
-- Re-derive every address. Returns nil+reason if the battle is not ready, so a
-- half-built state can never leave stale pointers in place.
function FPSYNC()
  local aa,P=FPAA,FPP
  local base=P("s:137D488")          if not base then return nil,"no base" end
  local M=P(aa(base,0x31C))          if not M then return nil,"no manager" end
  local A=P(aa(M,8))                 if not A then return nil,"no A" end
  local B=P(aa(A,0xB0))              if not B then return nil,"no B" end
  local D=P(aa(B,0x90))              if not D then return nil,"no entity array" end
  local hf=P(aa(A,0x9C))             if not hf then return nil,"no heightfield" end
  local data=P(hf)                   if not data then return nil,"no height data" end
  local ctl=P(aa(M,0x28140))         if not ctl then return nil,"no cam ctl" end
  local cam=P(aa(ctl,0x250))         if not cam then return nil,"no camera" end
  FPMGR = M
  FPSEEN = M
  FPD,FPCAM,FPDATA = D,cam,data
  FPCNT  = tonumber(ESE_ReadInt(aa(B,0x8C))) or 0
  FPSHIFT= tonumber(ESE_ReadInt(aa(hf,0x08)))
  FPOIDX = tonumber(ESE_ReadInt(aa(hf,0x10)))
  FPMAXI = tonumber(ESE_ReadInt(aa(hf,0x14)))
  FPORG  = tonumber(ESE_ReadFloat(aa(hf,0x1C)))
  FPCELL = tonumber(ESE_ReadFloat(aa(hf,0x20)))
  FPINV  = tonumber(ESE_ReadFloat(aa(hf,0x24)))
  FPROW  = 1 for _=1,(FPSHIFT or 0) do FPROW=FPROW*2 end
  FPSYNCS= (FPSYNCS or 0) + 1
  return true
end
FPI      = FPI      or 560
FPEYEH   = FPEYEH   or 1.8
FPEYEFOOT  = FPEYEFOOT  or 1.75   -- eye above a man's own origin, on foot
FPEYEMOUNT = FPEYEMOUNT or 1.45   -- seated rider: lower above his origin, which is already +1.0
FPEYELOCK  = FPEYELOCK  or false  -- true = always use FPEYEH, ignore mounted state
FPBLENDSEC = FPBLENDSEC or 1.2    -- seconds to fly into first person
FPBLEND    = 1                    -- 1 = settled; <1 = mid-transition
FPYAW    = FPYAW    or 3.0
FPPITCH  = FPPITCH  or 0.0
FPFWD    = FPFWD    or 0.0
FPSIDE   = FPSIDE   or 0.0
FPAUTO   = FPAUTO   or false
FPTURN   = FPTURN   or 0.12
FPYAWOFF = FPYAWOFF or 0.0
FPRUNS   = 0
FPSTALE  = 0
FPCTLON  = false          -- controls are OPT-IN; see fpctl.lua
-- Start on the RTS camera. An unset FPOFF is not "off": FPSTEP treats only
-- true as off, so the first tick used to glue the camera to soldier 560.
FPOFF    = true
function FPGROUND(x,z)
  local aa=FPAA
  local ix=math.floor(x*FPINV)+FPOIDX if ix>FPMAXI then ix=FPMAXI end if ix<0 then ix=0 end
  local iz=math.floor(z*FPINV)+FPOIDX if iz>FPMAXI then iz=FPMAXI end if iz<0 then iz=0 end
  local fx=(x-(ix*FPCELL-FPORG))*FPINV if fx<0 then fx=0 elseif fx>1 then fx=1 end
  local fz=(z-(iz*FPCELL-FPORG))*FPINV if fz<0 then fz=0 elseif fz>1 then fz=1 end
  local ix1=ix+1 if ix1>FPMAXI then ix1=FPMAXI end
  local iz1=iz+1 if iz1>FPMAXI then iz1=FPMAXI end
  local r0,r1=iz*FPROW,iz1*FPROW
  local function G(k) return tonumber(ESE_ReadFloat(aa(FPDATA,k*8))) or 0 end
  return (1-fx)*fz*G(r1+ix)+fx*fz*G(r1+ix1)+(1-fx)*(1-fz)*G(r0+ix)+fx*(1-fz)*G(r0+ix1)
end
-- Hotkeys that only affect the CAMERA, so they run regardless of FPCTLON and
-- can never issue a unit order. "=" (DIK 0x0D) toggles first person on/off.
FPHOTKEY = FPHOTKEY or "0D"
FPHOTPREV = false
FPPICKKEY = FPPICKKEY or "0C"
FPPICKPREV = false
-- Start a cinematic move: remember where the camera IS, then FPSTEP eases
-- from there to the soldier's eye instead of cutting. Called when entering
-- first person and when hooking a new man, so switching soldiers glides too.
function FPBEGIN()
  local aa=FPAA
  FPB0X=tonumber(ESE_ReadFloat(aa(FPCAM,0x08)))
  FPB0Y=tonumber(ESE_ReadFloat(aa(FPCAM,0x0C)))
  FPB0Z=tonumber(ESE_ReadFloat(aa(FPCAM,0x10)))
  FPB0FX=tonumber(ESE_ReadFloat(aa(FPCAM,0x60)))
  FPB0FY=tonumber(ESE_ReadFloat(aa(FPCAM,0x64)))
  FPB0FZ=tonumber(ESE_ReadFloat(aa(FPCAM,0x68)))
  FPBLENDSTEP = 0.016/(FPBLENDSEC or 1.2)
  FPBLEND = (FPB0X and FPB0FX) and 0 or 1
end

function FPHOT()
  if not ESE_Input then return end
  local d = (ESE_Input(FPHOTKEY) == "1")
  if d and not FPHOTPREV then
    if FPOFF then
      -- coming back: the battle may have been rebuilt while we were away
      if not FPP(FPAA(FPD, FPI*4)) then FPSYNC() end
      FPBEGIN()
      FPOFF = false
    else
      FPOFF = true
    end
  end
  FPHOTPREV = d
  -- "-" (DIK 0x0C) hooks whichever soldier is under the crosshair.
  -- Camera only, so it stays safe with controls off.
  local p = (ESE_Input(FPPICKKEY) == "1")
  if p and not FPPICKPREV and FPPICK then FPBEGIN() FPPICK(true) FPOFF = false end
  FPPICKPREV = p
end

function FPSTEP()
  if FPOFF then return end
  -- Re-read the manager every frame. If it changed, the cached camera is dead.
  -- Do not write it, and do not adopt the new one on the same frame.
  if not FPFRESH() then
    FPOFF = true
    FPSYNC()
    return
  end
  local aa,P=FPAA,FPP
  local u=P(aa(FPD,FPI*4))
  if not u then
    FPOFF = true
    FPCTLON = false
    FPCAM, FPD, FPDATA, FPMGR = nil, nil, nil, nil
    return
  end
  FPSTALE=0
  local x=tonumber(ESE_ReadFloat(aa(u,0x48)))
  local z=tonumber(ESE_ReadFloat(aa(u,0x50)))
  if not x or not z or x~=x or z~=z then return end
  if x<-1024 or x>1024 or z<-1024 or z>1024 then return end
  if FPAUTO then
    local want
    local fa=tonumber(ESE_ReadFloat(aa(u,0x1A0)))
    local fb=tonumber(ESE_ReadFloat(aa(u,0x1A8)))
    if fa and fb and fa==fa and fb==fb and math.abs(fa*fa+fb*fb-1)<0.05 then
      want=math.atan2(fa,fb)*180/math.pi
    elseif FPPX then
      local mx,mz=x-FPPX,z-FPPZ
      if (mx*mx+mz*mz)>0.0004 then want=math.atan2(mx,mz)*180/math.pi end
    end
    if want then
      local d=want+FPYAWOFF-FPYAW
      while d>180 do d=d-360 end
      while d<-180 do d=d+360 end
      FPYAW=FPYAW+d*FPTURN
    end
  end
  FPPX,FPPZ=x,z
  local yr=FPYAW*math.pi/180
  local pr=FPPITCH*math.pi/180
  local cp=math.cos(pr)
  local fx,fy,fz=math.sin(yr)*cp,math.sin(pr),math.cos(yr)*cp
  local ex=x+fx*FPFWD+fz*FPSIDE
  local ez=z+fz*FPFWD-fx*FPSIDE
  local my=tonumber(ESE_ReadFloat(aa(u,0x4C)))
  local lift=(my and (my-FPGROUND(x,z))) or 0
  -- lift is 1.00 for a mounted man and 0.00 on foot, so it doubles as the
  -- mounted flag and updates itself the moment a dragoon dismounts.
  FPMOUNTED = (lift > 0.5)
  local eo = FPEYEH
  if not FPEYELOCK then eo = FPMOUNTED and FPEYEMOUNT or FPEYEFOOT end
  local y=FPGROUND(ex,ez)+lift+eo
  local c=FPCAM
  if FPBLEND and FPBLEND < 1 then
    FPBLEND = FPBLEND + (FPBLENDSTEP or 0.02)
    if FPBLEND > 1 then FPBLEND = 1 end
    local s = FPBLEND*FPBLEND*(3-2*FPBLEND)   -- smoothstep: ease in and out
    ex = FPB0X + (ex-FPB0X)*s
    y  = FPB0Y + (y -FPB0Y)*s
    ez = FPB0Z + (ez-FPB0Z)*s
    local nx,ny,nz = FPB0FX+(fx-FPB0FX)*s, FPB0FY+(fy-FPB0FY)*s, FPB0FZ+(fz-FPB0FZ)*s
    local L = math.sqrt(nx*nx+ny*ny+nz*nz)
    if L > 0.0001 then fx,fy,fz = nx/L, ny/L, nz/L end
  end
  ESE_WriteFloat(aa(c,0x08),ex) ESE_WriteFloat(aa(c,0x0C),y) ESE_WriteFloat(aa(c,0x10),ez)
  ESE_WriteFloat(aa(c,0x60),fx) ESE_WriteFloat(aa(c,0x64),fy) ESE_WriteFloat(aa(c,0x68),fz)
  ESE_WriteFloat(aa(c,0x14),ex+fx*200) ESE_WriteFloat(aa(c,0x18),y+fy*200) ESE_WriteFloat(aa(c,0x1C),ez+fz*200)
  FPRUNS=FPRUNS+1
  FPLASTY=y
end
local ok,why = FPSYNC()
if not ok then return "setup FAILED: "..tostring(why) end
-- Do not call FPSTEP here. FPOFF starts true, and a call before the player
-- presses "=" would still write the camera if that flag were ever cleared.
return string.format("setup ok (sync #%d): cam=%s D=%s n=%d | following %d eye=+%.1f y=%.2f  controls=OFF",
  FPSYNCS, FPCAM, FPD, FPCNT, FPI, FPEYEH, FPLASTY or 0)
