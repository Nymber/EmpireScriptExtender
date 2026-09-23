-- Production chains. Loaded because this folder is listed in ese_mods.lua.
-- ESE.mod_dir is this folder, with a trailing backslash, set
-- by the loader before this file runs. Delete the folder and regenerate the
-- list to remove the mod; nothing else names it.
--
-- The engine owns production, pricing and display; this owns CONVERSION.
-- Empire has no native concept of a building consuming a commodity, and the
-- six demand drivers that express one good driving another are string literals
-- in a fixed array, so a seventh cannot be added.
--
-- WHAT IS STILL MISSING: per-faction production quantities. Every campaign
-- condition that mentions a commodity is a boolean existence check. Until a
-- native reader supplies amounts, ESE.chain_production stays nil and the tick
-- runs on whatever the region accumulator gathered.

local base = ESE.mod_dir or [[EmpireScriptExtender\lua\production chains\]]

local function clog(s)
  if ESE.notes then ESE.notes[#ESE.notes+1] = tostring(s) end
  if type(ESE_Log) == 'function' then ESE_Log('[chain] ' .. tostring(s)) end
end

-- Same guard the loader uses. A wrong-arity condition is an access violation,
-- which pcall does not catch; ESE_Protect arms the vectored exception handler.
local function safe(label, fn)
  if type(ESE.safe) == 'function' then return ESE.safe(label, fn) end
  local ok, err = pcall(fn)
  if not ok and ESE.faults then ESE.faults[#ESE.faults+1] = label .. ': ' .. tostring(err) end
end

ESE.chain = nil
do
  local f, ferr = loadfile(base .. 'chain_sim.lua')
  if not f then
    clog('chain_sim.lua did not load - ' .. tostring(ferr))
  else
    local ok, M = pcall(f)
    if not ok then
      clog('chain_sim.lua errored - ' .. tostring(M))
    else
      ESE.chain = M
      local _, where = M.load_recipes(base .. 'chain_recipes.lua')
      -- save_value/load_value would keep stockpiles inside the save, but
      -- nothing in this state persists, so this is a file. It does NOT rewind
      -- when the player loads an earlier save.
      M.use_file_store(base .. 'chain_stock.lua')
      -- Targets are written by the Stock Controls tab, in the UI lua_State.
      -- Their own file, because flush() rewrites the stock file wholesale from
      -- a copy loaded here at startup and would erase a mid-turn UI write.
      M.use_target_file(base .. 'chain_targets.lua')
      local _, bmsg = M.load_buildings(base .. 'chain_buildings.lua')
      M.load_prices(base .. 'chain_prices.lua')
      clog('buildings ' .. tostring(bmsg))
      clog('loaded, recipes from ' .. tostring(where) .. ', store=' .. M.store.kind)
    end
  end
end

ESE.chain_accum = {}
ESE.chain_regions = 0
if ESE.chain and type(events) == 'table' and type(events.RegionTurnStart) == 'table' then
  events.RegionTurnStart[#events.RegionTurnStart+1] = function(context)
    safe('chain-region', function()
      -- Count only regions that were actually accumulated. RegionTurnStart
      -- fires for every region in the world, and accumulate_region skips the
      -- ones that are not ours. It returns a number when it counted.
      local _, info = ESE.chain.accumulate_region(context, ESE.chain_accum)
      if type(info) == 'number' then
        ESE.chain_regions = ESE.chain_regions + 1
      end
    end)
  end
  clog('production accumulator on RegionTurnStart')
end
if ESE.chain and type(events) == 'table' and type(events.FactionTurnStart) == 'table' then
  events.FactionTurnStart[#events.FactionTurnStart+1] = function(context)
    safe('chain-tick', function()
      if not conditions.FactionIsHuman(LocalFaction, context) then return end
      local M = ESE.chain
      -- Gathered by the RegionTurnStart handlers above, which run before the
      -- faction turn. Asking here would see one region and a plausible zero.
      local production = ESE.chain_accum or {}
      local nregions = ESE.chain_regions or 0
      ESE.chain_accum = {}
      ESE.chain_regions = 0
      if type(ESE.chain_production) == 'function' then
        local ok, t = pcall(ESE.chain_production, context)
        if ok and type(t) == 'table' then production = t end
      end
      local n = 0
      for _ in pairs(production) do n = n + 1 end
      local res = M.run_turn(tostring(LocalFaction), production, M.recipes, M.prices,
        function(amount)
          if type(effect) == 'table' and type(effect.adjust_treasury) == 'function' then
            effect.adjust_treasury(amount, context)
          end
        end)
      M.flush()
      if n == 0 then
        clog(nregions .. ' region(s), no production this turn')
      else
        clog(M.format_report(tostring(LocalFaction), res))
      end
      ESE.chain_last = res
    end)
  end
  clog('conversion on FactionTurnStart')
end
