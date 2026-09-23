-- ============================================================================
-- ese_autoexec.lua - Empire trade mod, rebuilt on REAL engine data.
--
-- Runs automatically in every campaign scripting state (loaded by ESE once the
-- `events` table exists). Lives in the GAME ROOT next to Empire.exe.
--
-- DESIGN: every number here comes from the engine's own simulation via
-- `conditions`. Nothing is synthesised. 
-- ============================================================================

ESE = ESE or {}
ESE.version = '0.3 (shared mod runtime)'
ESE.notes   = {}
ESE.faults  = {}

local function log(s) ESE.notes[#ESE.notes+1] = tostring(s) end

-- Run fn with ESE's NATIVE crash guard armed. pcall alone is not enough.
local function safe(label, fn)
  if type(ESE_Protect) ~= 'function' then
    local ok, err = pcall(fn)
    if not ok then ESE.faults[#ESE.faults+1] = label .. ': ' .. tostring(err) end
    return
  end
  local r = ESE_Protect(fn)
  if r ~= 'true' then ESE.faults[#ESE.faults+1] = label .. ': ' .. tostring(r) end
end
ESE.safe = safe

-- Load the shared registry and hook bus before campaign features register.
-- The actual mods load at the end, after this file has defined its reporting API.
local ESE_ROOT = os.getenv('ESE_MODS_DIR')
if not ESE_ROOT or ESE_ROOT == '' then ESE_ROOT = os.getenv('ESE_CHAIN_DIR') end
if not ESE_ROOT or ESE_ROOT == '' then ESE_ROOT = [[EmpireScriptExtender\lua\]] end
ESE_ROOT = ESE_ROOT:gsub('/', '\\')
if ESE_ROOT:sub(-1) ~= '\\' then ESE_ROOT = ESE_ROOT .. '\\' end
local core_chunk, core_error = loadfile(ESE_ROOT .. 'ese_core.lua')
if core_chunk then
  local core_ok, core_result = pcall(core_chunk)
  if not core_ok and type(ESE_Log) == 'function' then
    ESE_Log('[core] campaign runtime failed: ' .. tostring(core_result))
  end
elseif type(ESE_Log) == 'function' then
  ESE_Log('[core] campaign bootstrap failed: ' .. tostring(core_error))
end

-- ============================================================================
-- STATE
-- ============================================================================
ESE.econ    = {}   -- faction-level, refreshed on each of our turns
ESE.regions = {}   -- per-region samples for the current turn
ESE.history = {}   -- one compact row per turn, for trends
ESE.alerts  = {}   -- what the player should be told this turn
ESE.signals = {}
-- set false to silence the turn-start popup (ESE.report() still works on demand)
ESE.auto_report = true

-- ============================================================================
-- ANALYSIS - turn engine facts into economic signals
-- ============================================================================
function ESE.analyse()
  local a, r = {}, ESE.regions
  local n = #r
  local blocked, hungry, stalled, shrinking, unrest = 0, 0, 0, 0, 0
  local growth_sum = 0

  for _, x in ipairs(r) do
    if x.unexported then blocked = blocked + 1 end
    if x.food_short then hungry  = hungry  + 1 end
    if x.growth_low then stalled = stalled + 1 end
    if x.riots or x.rebels then unrest = unrest + 1 end
    local g = tonumber(x.wealth_grow) or 0
    growth_sum = growth_sum + g
    if g < 0 then shrinking = shrinking + 1 end
  end

  ESE.signals = {
    regions = n, blocked = blocked, hungry = hungry, stalled = stalled,
    shrinking = shrinking, unrest = unrest,
    avg_growth = (n > 0) and (growth_sum / n) or 0,
  }

  -- SCARCITY SIGNAL: goods exist but cannot reach demand. In Sowell's terms the
  -- price system is being prevented from clearing - surplus and shortage coexist
  -- because the link between them is blocked.
  if blocked > 0 then
    a[#a+1] = ('%d region%s producing trade goods that cannot be exported.')
      :format(blocked, blocked == 1 and ' is' or 's are')
    if ESE.econ.idle_route then
      a[#a+1] = 'Unused international trade routes - that surplus has nowhere to go.'
    end
  end
  if hungry > 0 then
    a[#a+1] = ('%d region%s short of food while trade sits idle.')
      :format(hungry, hungry == 1 and ' is' or 's are')
  end

  -- INTERFERENCE COST: upkeep crowding out investment
  local sup = tonumber(ESE.econ.support_pct) or 0
  if sup >= 90 then
    a[#a+1] = ('Upkeep consumes %d%% of income - almost nothing is left to invest.'):format(sup)
  elseif sup >= 70 then
    a[#a+1] = ('Upkeep is %d%% of income; growth stalls before it shows in the treasury.'):format(sup)
  end

  -- TREND: falling trade WHILE regions report blockage is the informative case
  local h = ESE.history
  if #h >= 2 then
    local prev, now = h[#h-1], h[#h]
    local d = (tonumber(now.trade) or 0) - (tonumber(prev.trade) or 0)
    ESE.signals.trade_delta = d
    if d < 0 and blocked > 0 then
      a[#a+1] = ('Trade income fell by %d while %d region%s could not export - the loss is not demand, it is access.')
        :format(-d, blocked, blocked == 1 and '' or 's')
    end
  end

  if stalled > 0 and sup >= 70 then
    a[#a+1] = ('%d region%s with stalled growth while upkeep eats the surplus.')
      :format(stalled, stalled == 1 and '' or 's')
  end

  ESE.alerts = a
end

-- ============================================================================
-- FACTION SAMPLE  (FactionTurnStart fires for ~43 factions; ours only)
-- ============================================================================
if type(ESE.on_event) == 'function' then
  ESE.on_event('FactionTurnStart', 'core.economy-faction', function(context)
      if not conditions.FactionIsHuman(LocalFaction, context) then return end

      local e = {}
      e.turn        = conditions.TurnNumber(context)
      e.treasury    = conditions.FactionTreasury(context)
      e.cashflow    = conditions.FactionCashFlow(context)
      e.trade_value = conditions.FactionTradeValue(context)
      e.trade_pct   = conditions.FactionTradeValuePercentage(context)
      e.support_pct = conditions.SupportCostsPercentage(context)
      e.losing      = conditions.LosingMoney(context)
      e.idle_route  = conditions.UnusedInternationalTradeRoute(context)
      ESE.econ = e

      ESE.history[#ESE.history+1] = {
        turn = e.turn, trade = e.trade_value, treasury = e.treasury,
        cash = e.cashflow, support = e.support_pct
      }
      if #ESE.history > 200 then table.remove(ESE.history, 1) end

      -- Regions for THIS turn were collected by RegionTurnStart handlers, which
      -- run before our faction turn begins; analyse now, then clear for next.
      ESE.analyse()
      ESE.last_regions = ESE.regions
      ESE.regions = {}

      -- Tell the player, unprompted. ESE_Say bridges to the UI lua_State,
      -- which is the only place panelmanager works; the campaign state cannot
      -- open a panel itself. Only speak when there is something worth saying.
      if ESE.auto_report and #ESE.alerts > 0 and type(ESE_Say) == 'function' then
        ESE_Say(ESE.report())
      end
  end, 50)
  log('faction sampler on FactionTurnStart')
end

-- ============================================================================
-- REGION SAMPLE  (RegionTurnStart; ours only)
-- ============================================================================
if type(ESE.on_event) == 'function' then
  ESE.on_event('RegionTurnStart', 'core.economy-region', function(context)
      if not conditions.RegionIsLocal(context) then return end
      ESE.regions[#ESE.regions+1] = {
        unexported  = conditions.RegionHasUnexportedTrade(context),
        food_short  = conditions.RegionHasFoodShortages(context),
        growth_low  = conditions.RegionEconomicGrowthLow(context),
        wealth_grow = conditions.RegionTownWealthGrowth(context),
        wealth_inc  = conditions.RegionWealthIncrease(context),
        pop_low     = conditions.RegionPopulationLow(context),
        riots       = conditions.RegionRiots(context),
        rebels      = conditions.RegionRebels(context),
        slots       = conditions.RegionSlotCount(context),
        tax_exempt  = conditions.RegionTaxExempt(context),
      }
  end, 50)
  log('region sampler on RegionTurnStart')
end

-- ============================================================================
-- REPORTING
-- ============================================================================
function ESE.report()
  local e, s = ESE.econ, ESE.signals or {}
  if not e.turn then return 'no sample yet - end a turn' end
  local lines = {
    ('TRADE REPORT  -  turn %s  (%s)'):format(tostring(e.turn), tostring(LocalFaction)),
    '',
    ('Treasury      %s'):format(tostring(e.treasury)),
    ('Cash flow     %.1f'):format(tonumber(e.cashflow) or 0),
    ('Trade value   %s  (%.2f%% of world trade)'):format(tostring(e.trade_value), tonumber(e.trade_pct) or 0),
    ('Upkeep        %s%% of income'):format(tostring(e.support_pct)),
    '',
    ('Regions %d   blocked %d   food short %d   stalled %d   unrest %d')
      :format(s.regions or 0, s.blocked or 0, s.hungry or 0, s.stalled or 0, s.unrest or 0),
    ('Avg town wealth growth  %.1f'):format(s.avg_growth or 0),
  }
  if #ESE.alerts > 0 then
    lines[#lines+1] = ''
    for _, m in ipairs(ESE.alerts) do lines[#lines+1] = '* ' .. m end
  end
  return table.concat(lines, '\n')
end

-- compact one-liner for the REPL
function ESE.dump()
  local e, s = ESE.econ, ESE.signals or {}
  return ('turn=%s treasury=%s trade=%s upkeep=%s%% | regions=%s blocked=%s hungry=%s stalled=%s | alerts=%d | faults=%s')
    :format(tostring(e.turn), tostring(e.treasury), tostring(e.trade_value), tostring(e.support_pct),
            tostring(s.regions), tostring(s.blocked), tostring(s.hungry), tostring(s.stalled),
            #ESE.alerts, (#ESE.faults > 0 and table.concat(ESE.faults, ' | ') or 'none'))
end

log('ESE trade mod ' .. ESE.version .. ' loaded')

-- ============================================================================
-- 9th-COMMODITY INVESTIGATION  (temporary; remove once answered)
--
-- The crash at static 0x00951A71 happens AFTER campaign script init - proven,
-- because this autoexec runs and is logged before the fault. So we read the
-- engine's own commodity structures HERE, while they exist, and write them
-- straight to ese_log.txt (which flushes per line and therefore survives the
-- crash). The pipe cannot do this: there is no way to hand-time a request into
-- that window.
--
-- Pointer chain (verified earlier, see project_trade_mod_global_world_pointer):
--     DAT_01473a78 + delta      -> world pointer slot
--     [world + 0x924]           -> object
--     [that + 0x8]              -> manager table
--     [managers + 0xC84]        -> trade manager
--     [trade_manager + 0xB8]    -> commodity count  (read 9 via CE earlier)
--
-- Commodity DATABASE_TABLE layout (decoded live):
--     +0x08 count, +0x0C not-found sentinel (== count), +0x10 record array
--     COMMODITY_RECORD = 12 bytes: name ptr, float price, float elasticity
-- ============================================================================
if type(ESE_ReadInt) == 'function' and type(ESE_Log) == 'function' then
  ESE.safe('commodity-probe', function()
    local function hex(n) return string.format('0x%X', n) end
    local function rd(a) local v = ESE_ReadInt(a) return tonumber(v) end

    local delta = tonumber(ESE_Delta()) or 0
    ESE_Log('=== 9th-commodity probe ===')
    ESE_Log('delta = ' .. ESE_Delta())

    local worldSlot = 0x01473A78 + delta
    ESE_Log('world slot @' .. hex(worldSlot) .. ' = ' .. tostring(ESE_ReadInt(hex(worldSlot))))

    local w = rd(hex(worldSlot))
    if not w or w == 0 then ESE_Log('world pointer null - chain stops') return end

    local a = rd(hex(w + 0x924))
    ESE_Log('[world+0x924] = ' .. tostring(a))
    if not a or a == 0 then return end

    local mgrs = rd(hex(a + 0x8))
    ESE_Log('[+0x8] managers = ' .. tostring(mgrs))
    if not mgrs or mgrs == 0 then return end

    local trade = rd(hex(mgrs + 0xC84))
    ESE_Log('[managers+0xC84] trade manager = ' .. tostring(trade))
    if not trade or trade == 0 then return end

    -- THE question: does the trade manager agree that there are 9 commodities?
    ESE_Log('trade_manager+0xB8 (commodity count) = ' .. tostring(ESE_ReadInt(hex(trade + 0xB8))))

    -- sweep nearby count-like fields: a consumer still holding 8 is the bug
    local sweep = {}
    for off = 0xA0, 0xE0, 4 do
      local v = rd(hex(trade + off))
      if v and v >= 0 and v <= 64 then sweep[#sweep+1] = string.format('+0x%X=%d', off, v) end
    end
    ESE_Log('small ints near +0xB8: ' .. table.concat(sweep, ' '))
    ESE_Log('trade manager bytes +0xA0: ' .. ESE_ReadBytes(hex(trade + 0xA0), '#64'))
    ESE_Log('=== probe end ===')
  end)
end


-- ============================================================================
-- CONFIGURED MODS
-- ============================================================================
if type(ESE.load_configured_mods) == 'function' then
  ESE.load_configured_mods('campaign')
elseif type(ESE_Log) == 'function' then
  ESE_Log('[core] campaign mods skipped because the shared runtime did not load')
end
