# patch_stock_toggle.rb - drive the full-panel Stock Controls grid: a name, a
# target and a working checkbox per commodity.
#
# THE MODEL
#   Two numbers per good, both in chain_targets.lua (the UI owns that file):
#       stockon_<faction>_<good>  1 = stock this good, 0/absent = sell it all
#       target_<faction>_<good>   how much to hold back once stocking is on
#   The checkbox drives the first, clicking the number cycles the second.
#   chain_sim.get_target returns 0 when the flag is off, so an unticked box is
#   exactly vanilla behaviour no matter what target is remembered.
#
# THE CHECKBOX PROTOCOL is the panel's own, read out of Notify():
#       "down"          -> just TICKED
#       "selected_down" -> just UNTICKED
#   Any other state (roll, inactive...) is ignored rather than guessed at.
#
# Run AFTER patch_stock_cycle.rb - it reuses ReadChainTargets/WriteChainTargets
# and replaces RefreshStockControls.
#
# Usage
#   ruby patch_stock_toggle.rb <government_screens.lua> [--out F] [--apply]

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
path  = ARGV[0]
apply = ARGV.include?("--apply")
out   = opt("out", path)
abort "usage: ruby patch_stock_toggle.rb <government_screens.lua> [--out F] [--apply]" unless path && File.file?(path)

src = File.read(path, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").gsub("\r\n", "\n")

if src.include?("function ToggleStockTarget")
  puts "already patched - nothing to do"
  exit 0
end
%w[ReadChainTargets WriteChainTargets RefreshStockControls g_market_dbkey].each do |need|
  abort "#{need} is missing - run patch_stock_cycle.rb first" unless src.include?(need)
end

goods = src[/^g_market_dbkey = \{.*?^\}/m].to_s.scan(/^\s*\["([^"]+)"\]\s*=/).flatten
abort "could not read g_market_dbkey" if goods.size < 8

TOGGLES = goods.map { |g|
  "function ToggleStock_#{g}(state) ToggleStockTarget(#{g.inspect}, state) end"
}.join("\n")

old_re = /^function RefreshStockControls\(\).*?\nend\n/m
abort "could not locate RefreshStockControls" unless src =~ old_re

replacement = <<~LUA
  -- A good is stocked only when its box is ticked. Absent means unticked,
  -- which is vanilla behaviour (sell everything) - so the grid is inert until
  -- the player opts a commodity in.
  function IsStocking(dbkey, targets)
    return (targets["stockon_" .. g_chain_faction .. "_" .. dbkey] or 0) ~= 0
  end

  -- state comes straight from Component.Call("CurrentState") in the checkbox's
  -- own script, which is how the two vanilla automanage boxes report too.
  function ToggleStockTarget(uiname, state)
    local db = g_market_dbkey[uiname]
    if db == nil then return end
    local t = ReadChainTargets()
    local k = "stockon_" .. g_chain_faction .. "_" .. db
    if state == "down" then
      t[k] = 1
      -- Ticking a good with no target yet would stock nothing, which reads as
      -- a broken checkbox. Give it the first real step.
      local tk = "target_" .. g_chain_faction .. "_" .. db
      if (t[tk] or 0) == 0 then t[tk] = g_target_steps[2] or 100 end
    elseif state == "selected_down" then
      t[k] = 0
    else
      return
    end
    WriteChainTargets(t)
    RefreshStockControls()
  end

  #{TOGGLES}

  function RefreshStockControls()
    local window = UIComponent(this:Find("stock market"))
    if window == nil then return end
    local stock = ReadChainStock()
    local targets = ReadChainTargets()
    for uiname, dbkey in pairs(g_market_dbkey) do
      local slot = window:Find("stk_" .. uiname)
      if slot ~= nil then
        local c = UIComponent(slot)
        local have = stock["chain_" .. g_chain_faction .. "_" .. dbkey] or 0
        local want = targets["target_" .. g_chain_faction .. "_" .. dbkey] or 0
        local on = IsStocking(dbkey, targets)

        local nmc = c:Find("stk_name")
        if nmc ~= nil then
          -- g_market_tooltips holds the full description; the first line of it
          -- is the display name, which is what fits a 88px column.
          local full = g_market_tooltips[uiname] or uiname
          local nl = string.find(full, "\\n")
          if nl ~= nil then full = string.sub(full, 1, nl - 1) end
          UIComponent(nmc):SetStateText(full)
        end

        local v = c:Find("dy_value")
        if v ~= nil then
          UIComponent(v):SetStateText(on and (have .. "/" .. want) or "-")
        end

        local chk = c:Find("stk_check")
        if chk ~= nil then
          local cu = UIComponent(chk)
          cu:SetState(on and "selected" or "normal")
          -- The box is a CLONE of the automanage-taxes checkbox, so it
          -- arrived carrying that box's tooltip; build_stock_panel.rb blanks
          -- the baked-in one and this puts a true one in its place. Without
          -- it, hovering the box explains how to manage taxes manually.
          cu:SetTooltipText(on
            and ("Stocking " .. (g_market_dbkey[uiname] and uiname or uiname) ..
                 "\\nUntick to sell everything produced")
            or  ("Not stocking " .. uiname ..
                 "\\nTick to hold this back from trade"))
        end

        local tip = g_market_tooltips[uiname] or uiname
        if on then
          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..
                           "\\nHolding back until: " .. want ..
                           "\\n\\nClick the number to cycle: 0 / 100 / 500 / 2000" ..
                           "\\nUntick to sell everything produced")
        else
          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..
                           "\\nNot stocking - selling everything produced" ..
                           "\\n\\nTick the box to start holding this back")
        end
      end
    end
  end
LUA

src = src.sub(old_re, replacement)

n_tog = src.scan(/^function ToggleStock_/).size
abort "emitted #{n_tog} toggles for #{goods.size} commodities" unless n_tog == goods.size
%w[ToggleStockTarget RefreshStockControls IsStocking].each do |f|
  n = src.scan(/^function #{f}\b/).size
  abort "#{f} defined #{n} times - expected 1" unless n == 1
end

puts "RefreshStockControls rewritten: name + stock/target + checkbox state"
puts "toggle handlers : #{n_tog} (one per commodity)"
puts "model           : stockon_<faction>_<good> drives it; target is the amount"

if apply
  File.write(out, src, mode: "wb")
  puts "\nwritten: #{out} (#{src.bytesize} bytes)"
else
  puts "\nDRY RUN (pass --apply to write)"
end
