# patch_stock_input.rb - make the per-row target a TYPED FIELD instead of a
# click-through of four presets.
#
# THE COMPONENT IS VANILLA'S. Empire has exactly one text-entry component,
# `input_name` on the save-game screen, whose behaviour comes from
# `template.text_input.lua`. build_stock_panel.rb clones it per row; this
# wires it up. The template's contract, read out of its own decompiled source:
#
#   input:LuaCall("Value")                  -> the typed string
#   input:LuaCall("SetValue", s)            -> set it
#   SetGlobal("CharacterValidator", fn)     -> fn(ch, cur) must return TRUE to
#                                              accept the character
#   SetGlobal("g_notify_func", fn)          -> fn(value) on FocusLose, which
#                                              RETURN / ENTER / ESCAPE trigger
#                                              via StealInputFocus(false)
#
# WHY NAMED FUNCTIONS RATHER THAN CLOSURES
#   The save screen passes a plain global function to SetGlobal
#   (`SetGlobal("CharacterValidator", ValidateFilename)`), which is the only
#   form demonstrated to survive the marshal into a component's own
#   environment. One named commit function per commodity keeps to that, the
#   same reasoning as the click wrappers.
#
# Run AFTER patch_stock_toggle.rb.
#
# Usage
#   ruby patch_stock_input.rb <government_screens.lua> [--out F] [--apply]

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
path  = ARGV[0]
apply = ARGV.include?("--apply")
out   = opt("out", path)
abort "usage: ruby patch_stock_input.rb <government_screens.lua> [--out F] [--apply]" unless path && File.file?(path)

src = File.read(path, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").gsub("\r\n", "\n")
if src.include?("function CommitStockTarget")
  puts "already patched - nothing to do"
  exit 0
end
%w[RefreshStockControls ReadChainTargets WriteChainTargets g_market_dbkey].each do |need|
  abort "#{need} is missing - run patch_stock_toggle.rb first" unless src.include?(need)
end

dbk = src[/^g_market_dbkey = \{.*?^\}/m]
abort "could not read g_market_dbkey" unless dbk
pairs = dbk.scan(/^\s*\["([^"]+)"\]\s*=\s*"([^"]+)"/)
abort "g_market_dbkey parsed as #{pairs.size} entries" if pairs.size < 8

COMMITS = pairs.map { |ui, db|
  "function CommitStock_#{ui}(v) CommitStockTarget(#{db.inspect}, v) end"
}.join("\n")
COMMIT_MAP = pairs.map { |ui, _| "  [#{ui.inspect}] = CommitStock_#{ui}," }.join("\n")

old_re = /^function RefreshStockControls\(\).*?\nend\n/m
abort "could not locate RefreshStockControls" unless src =~ old_re

replacement = <<~LUA
  -- NO CharacterValidator. The template gates every keystroke on
  --     CharacterValidator == nil or CharacterValidator(ch, value) == true
  -- so if the function does not arrive callable in the component's own
  -- environment, that call throws and EVERY character is dropped - which is
  -- exactly what happened: the caret appeared (focus and template fine) and
  -- nothing could be typed. Leaving the global unset takes the `== nil`
  -- branch, which is the path vanilla uses everywhere except the save screen.
  -- Non-numeric input is instead rejected at commit time by tonumber, so the
  -- stored target is still always a number.

  -- Called when the field loses focus, which RETURN and ESCAPE both cause.
  function CommitStockTarget(dbkey, v)
    local n = tonumber(v)
    if n == nil then n = 0 end
    if n < 0 then n = 0 end
    n = math.floor(n)
    local t = ReadChainTargets()
    t["target_" .. g_chain_faction .. "_" .. dbkey] = n
    -- Typing an amount means you want it held back; typing 0 means you do not.
    -- Without this the number would save and the sim would ignore it, because
    -- get_target returns 0 whenever the box is unticked.
    t["stockon_" .. g_chain_faction .. "_" .. dbkey] = (n > 0) and 1 or 0
    WriteChainTargets(t)
    RefreshStockControls()
  end

  #{COMMITS}

  g_commit_fn = {
  #{COMMIT_MAP}
  }

  -- Read every field and store what is in it. `g_notify_func` is still
  -- installed below, but it is the same SetGlobal mechanism that just failed
  -- for CharacterValidator - so committing must not depend on it alone.
  -- This runs on any row click and on any checkbox toggle, which means the
  -- grid works whether or not the hook ever fires.
  function CommitAllStockInputs()
    local window = UIComponent(this:Find("stock market"))
    if window == nil then return false end
    local t = ReadChainTargets()
    local changed = false
    for uiname, dbkey in pairs(g_market_dbkey) do
      local slot = window:Find("stk_" .. uiname)
      if slot ~= nil then
        local inp = UIComponent(slot):Find("stk_input")
        if inp ~= nil then
          local ok, v = pcall(function() return UIComponent(inp):LuaCall("Value") end)
          if ok and v ~= nil then
            local n = tonumber(v)
            if n == nil then n = 0 end
            if n < 0 then n = 0 end
            n = math.floor(n)
            local k = "target_" .. g_chain_faction .. "_" .. dbkey
            if (t[k] or 0) ~= n then
              t[k] = n
              t["stockon_" .. g_chain_faction .. "_" .. dbkey] = (n > 0) and 1 or 0
              changed = true
            end
          end
        end
      end
    end
    if changed then WriteChainTargets(t) end
    return changed
  end

  -- The row click used to step the target through four presets. With a typed
  -- field that is redundant and would fight the text, so it now commits what
  -- is typed instead. The CycleStock_* wrappers the slot scripts call are
  -- left in place and routed here.
  function CycleStockTarget(uiname, dir)
    if CommitAllStockInputs() then RefreshStockControls() end
  end

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
          local full = g_market_tooltips[uiname] or uiname
          local nl = string.find(full, "\\n")
          if nl ~= nil then full = string.sub(full, 1, nl - 1) end
          UIComponent(nmc):SetStateText(full)
        end

        local v = c:Find("dy_value")
        if v ~= nil then UIComponent(v):SetStateText(tostring(have)) end

        local inp = c:Find("stk_input")
        if inp ~= nil then
          local ic = UIComponent(inp)
          -- Install the hooks once per component. Doing it every refresh
          -- would also re-run while a field is mid-commit.
          if g_inputs_ready ~= true then
            -- Still offered, because Enter-to-commit is the nicest path when
            -- it works. Everything also commits via CommitAllStockInputs, so
            -- nothing depends on this succeeding.
            local fn = g_commit_fn[uiname]
            if fn ~= nil then pcall(function() ic:SetGlobal("g_notify_func", fn) end) end
          end
          -- The donor component has ONE state ("NewState"), so there is no
          -- greyed-out rendering to switch to. Rather than fake an inactive
          -- look, the field stays editable and the CHECKBOX is the master
          -- switch: an unticked row keeps its number but the sim reads 0.
          -- Typing an amount ticks the box, so the field is never a dead end.
          ic:LuaCall("SetValue", tostring(want))
        end

        local chk = c:Find("stk_check")
        if chk ~= nil then
          local cu = UIComponent(chk)
          cu:SetState(on and "selected" or "normal")
          cu:SetTooltipText(on
            and ("Stocking " .. uiname .. "\\nUntick to sell everything produced")
            or  ("Not stocking " .. uiname .. "\\nTick, or type an amount, to hold this back"))
        end

        local tip = g_market_tooltips[uiname] or uiname
        if on then
          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..
                           "\\nHolding back until: " .. want ..
                           "\\n\\nType an amount and press Enter to change it")
        else
          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..
                           "\\nNot stocking - selling everything produced" ..
                           "\\n\\nTick the box, or type an amount, to hold this back")
        end
      end
    end
    g_inputs_ready = true
  end
LUA

src = src.sub(old_re, replacement)

# Drop the cycle-through-presets version of CycleStockTarget. The replacement
# above defines its own, and leaving both would work only by luck of ordering
# while leaving dead code that reads as the live behaviour.
cyc_old = /^function CycleStockTarget\(uiname, dir\)\n  local db = g_market_dbkey.*?\n^end\n/m
abort "could not find the old CycleStockTarget to remove" unless src =~ cyc_old
src = src.sub(cyc_old, "")

# A checkbox click must save whatever is typed first, or ticking a box would
# discard an un-committed number sitting in the field next to it.
tog = "function ToggleStockTarget(uiname, state)\n"
abort "ToggleStockTarget missing" unless src.include?(tog)
src = src.sub(tog, tog + "  CommitAllStockInputs()\n")

n_c = src.scan(/^function CommitStock_/).size
abort "emitted #{n_c} commit functions for #{pairs.size} commodities" unless n_c == pairs.size
%w[CommitStockTarget RefreshStockControls CommitAllStockInputs CycleStockTarget].each do |f|
  n = src.scan(/^function #{f}\b/).size
  abort "#{f} defined #{n} times - expected 1" unless n == 1
end
# The map must reference functions that exist and be declared AFTER them, or
# every entry is nil at load time.
abort "g_commit_fn is declared before the functions it names" if
  src.index("g_commit_fn = {").to_i < src.index("function CommitStock_").to_i

puts "target field    : typed; non-numeric rejected at COMMIT (no CharacterValidator)"
puts "commit paths    : row click and checkbox click always; Enter only if SetGlobal works"
puts "commit handlers : #{n_c} named (offered to g_notify_func, not depended on)"
puts "row click       : now commits typed values instead of cycling presets"
puts "dy_value        : shows stock on hand; the field holds the target"

if apply
  File.write(out, src, mode: "wb")
  puts "\nwritten: #{out} (#{src.bytesize} bytes)"
else
  puts "\nDRY RUN (pass --apply to write)"
end
