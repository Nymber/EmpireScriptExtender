# patch_stock_cycle.rb - make the Stock Controls tab a CONTROL rather than a
# readout: left-click a commodity to raise its hold-back target, right-click to
# lower it.
#
# TWO FILES, ONE WRITER EACH
#   Targets are set here, in the UI lua_State; stock is written by chain_sim in
#   the CAMPAIGN state. They cannot call each other, so they share through
#   files - but chain_sim's flush() rewrites chain_stock.lua WHOLESALE from a
#   copy loaded at campaign start. A target written into that file from here
#   would be silently erased at the next end of turn: the click appears to
#   work, then quietly undoes itself a turn later.
#
#   So targets get their own file. This script writes ONLY chain_targets.lua,
#   and chain_sim re-reads it at the top of every turn.
#
#       chain_stock.lua    campaign writes, this reads
#       chain_targets.lua  this writes,     campaign re-reads each turn
#
# WHY THE REDRAW IS SPLIT OUT
#   SelectTab returns FALSE when the requested tab is already selected, and
#   ShowStockControls' whole body sits inside `if SelectTab("stock") then`.
#   Calling it to refresh after a click would therefore do nothing at all. The
#   body moves to RefreshStockControls, which both the tab handler and the
#   click handler call.
#
# Run AFTER patch_stock_tab.rb - this rewrites the ShowStockControls it adds.
#
# Usage
#   ruby patch_stock_cycle.rb <government_screens.lua> [--out F] [--apply]

require_relative "../../../empire_paths"

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
path  = ARGV[0]
apply = ARGV.include?("--apply")
out   = opt("out", path)
targets_path = opt("targets",
  File.join(EMPIRE.game, "EmpireScriptExtender/lua/chain_targets.lua"))

abort "usage: ruby patch_stock_cycle.rb <government_screens.lua> [--out F] [--apply]" unless path && File.file?(path)

# Normalise line endings before matching. An anchor written with \n silently
# fails against a \r\n file, and the failure looks like "the edit did nothing"
# rather than an error - that has cost a launch on this project already.
src = File.read(path, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").gsub("\r\n", "\n")

if src.include?("function CycleStockTarget")
  puts "already patched - nothing to do"
  exit 0
end
%w[g_market_dbkey g_chain_faction ShowStockControls].each do |need|
  abort "#{need} is missing - run patch_stock_tab.rb first" unless src.include?(need)
end

# ---------------------------------------------------------------- the anchor
# Match the whole existing ShowStockControls, from its header to the line that
# closes it, and replace it outright. Anchoring on the header alone and
# guessing the extent would risk swallowing ShowTrade.
old_re = /^function ShowStockControls\(\).*?\nend\n/m
abort "could not locate the ShowStockControls body" unless src =~ old_re
old = src[old_re]
abort "ShowStockControls body looks wrong (no 'stk_' lookup)" unless old.include?('"stk_"')

# ------------------------------------------------------- the click wrappers
# Read the commodity list out of g_market_dbkey in the source rather than
# hardcoding it, so this stays correct as commodities are added. Emitting the
# names explicitly (rather than building them with _G at runtime) keeps the
# generated file inspectable and avoids assuming _G is reachable in a panel's
# own environment.
dbk = src[/^g_market_dbkey = \{.*?^\}/m]
abort "could not read the g_market_dbkey table" unless dbk
goods = dbk.scan(/^\s*\["([^"]+)"\]\s*=/).flatten
abort "g_market_dbkey parsed as #{goods.size} entries - that cannot be right" if goods.size < 8
# Emitted at column 0. The heredoc below uses <<~, which strips the COMMON
# leading indentation of its literal lines - so the interpolation point must
# be indented like its neighbours, and this content must not be.
WRAPPERS = goods.map { |g|
  "function CycleStock_#{g}()     CycleStockTarget(#{g.inspect},  1) end\n" \
  "function CycleStockDown_#{g}() CycleStockTarget(#{g.inspect}, -1) end"
}.join("\n")

replacement = <<~LUA
  -- Targets are written HERE (the UI state) and read by chain_sim in the
  -- campaign state. They live in their own file because chain_sim's flush()
  -- rewrites chain_stock.lua wholesale from a copy loaded at campaign start,
  -- so a target written into that file would be erased at end of turn.
  g_chain_targets_path = [[#{targets_path}]]
  g_target_steps = { 0, 100, 500, 2000 }

  function ReadChainTargets()
    local t = {}
    local f = io.open(g_chain_targets_path, "rb")
    if f == nil then return t end
    local src = f:read("*a")
    f:close()
    local chunk = loadstring("return " .. src)
    if chunk == nil then return t end
    local ok, v = pcall(chunk)
    if ok and type(v) == "table" then return v end
    return t
  end

  -- Same serialisation chain_sim uses, so the two agree on the format.
  function WriteChainTargets(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = { "{" }
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format("  [%q] = %d,", k, t[k])
    end
    parts[#parts + 1] = "}"
    local f = io.open(g_chain_targets_path, "wb")
    if f == nil then return false end
    f:write(table.concat(parts, "\\n"))
    f:close()
    return true
  end

  -- Step this good's target along g_target_steps and redraw. dir is +1 for a
  -- left-click, -1 for a right-click; both wrap.
  function CycleStockTarget(uiname, dir)
    local db = g_market_dbkey[uiname]
    if db == nil then return end
    local t = ReadChainTargets()
    local k = "target_" .. g_chain_faction .. "_" .. db
    local cur = t[k] or 0
    local idx = 1
    for i, v in ipairs(g_target_steps) do
      if v == cur then idx = i break end
    end
    idx = idx + dir
    if idx > #g_target_steps then idx = 1 end
    if idx < 1 then idx = #g_target_steps end
    t[k] = g_target_steps[idx]
    WriteChainTargets(t)
    RefreshStockControls()
  end

  -- ONE NAMED WRAPPER PER COMMODITY, so the component scripts can use the
  -- ZERO-ARGUMENT LuaCall form that vanilla actually proves:
  --     parent:LuaCall("SelectPrevBuildPolicy")
  -- Passing the name as an argument would rest on LuaCall dispatching a
  -- string, which nothing here demonstrates - and the obvious fallback (park
  -- the name in a global from the component script) does not work either,
  -- because each panel script has its OWN environment: a probe of the live UI
  -- state found none of this panel's globals in it. Wrappers cost 23 lines
  -- and remove the unknown completely.
  #{WRAPPERS}

  -- The redraw, separated from tab selection: SelectTab returns false when the
  -- tab is ALREADY selected, so a click handler calling ShowStockControls
  -- would refresh nothing.
  function RefreshStockControls()
    local window = UIComponent(this:Find("stock market"))
    if window == nil then return end
    local stock = ReadChainStock()
    local targets = ReadChainTargets()
    for uiname, dbkey in pairs(g_market_dbkey) do
      local slot = window:Find("stk_" .. uiname)
      if slot ~= nil then
        local have = stock["chain_" .. g_chain_faction .. "_" .. dbkey] or 0
        local want = targets["target_" .. g_chain_faction .. "_" .. dbkey] or 0
        local c = UIComponent(slot)
        local v = c:Find("dy_value")
        if v ~= nil then UIComponent(v):SetStateText(tostring(want)) end
        local ga = c:Find("growth_arrow")
        if ga ~= nil then UIComponent(ga):SetVisible(false) end
        -- Only OnLeftClickUp has precedent in this panel, so the left click
        -- WRAPS through the whole ladder and is a complete control on its
        -- own. A right-click handler is emitted too, but nothing promises
        -- the engine dispatches that event here - so it is not advertised.
        local tip = g_market_tooltips[uiname] or uiname
        if want > 0 then
          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..
                           "\\nHolding back until: " .. want ..
                           "\\n\\nClick to cycle: 0 / 100 / 500 / 2000")
        else
          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..
                           "\\nSelling everything produced" ..
                           "\\n\\nClick to cycle: 0 / 100 / 500 / 2000")
        end
      end
    end
  end

  function ShowStockControls()
    if SelectTab("stock") then
      RefreshStockControls()
    end
  end
LUA

src = src.sub(old_re, replacement)

# ------------------------------------------------- Trade tab reads them too
# ShowTrade shows the target in its tooltips and was reading it out of the
# stock table. That key no longer exists there.
trade_old = 'local want = stock["target_" .. g_chain_faction .. "_" .. db] or 0'
trade_new = 'local want = ReadChainTargets()["target_" .. g_chain_faction .. "_" .. db] or 0'
trade_fixed = src.include?(trade_old)
src = src.sub(trade_old, trade_new) if trade_fixed

n_wrap = src.scan(/^\s*function CycleStock_/).size
abort "emitted #{n_wrap} click wrappers for #{goods.size} commodities" unless n_wrap == goods.size

puts "ShowStockControls  -> RefreshStockControls + wrapper"
puts "added              : ReadChainTargets, WriteChainTargets, CycleStockTarget"
puts "click wrappers     : #{n_wrap} (zero-argument, one per commodity)"
puts "targets file       : #{targets_path}"
puts "ShowTrade target read repointed at the targets file: #{trade_fixed ? 'yes' : 'NO - check it'}"
puts "steps              : 0 -> 100 -> 500 -> 2000 -> 0"

# A balance check catches a truncated or doubled block before the game does.
%w[CycleStockTarget RefreshStockControls ReadChainTargets WriteChainTargets].each do |f|
  n = src.scan(/^function #{f}\b/).size
  abort "#{f} defined #{n} times - expected 1" unless n == 1
end
abort "ShowStockControls defined #{src.scan(/^function ShowStockControls\b/).size} times" unless
  src.scan(/^function ShowStockControls\b/).size == 1

if apply
  File.write(out, src, mode: "wb")
  puts "\nwritten: #{out} (#{src.bytesize} bytes)"
else
  puts "\nDRY RUN (pass --apply to write)"
end
