# patch_market_scroll.rb - teach government_screens.lua to drive the World
# Market scrollbar added by add_market_scrollbar.rb.
#
# A patcher rather than a hand-edit so it can be re-applied to a fresh unluac
# decompile whenever the script is re-derived. Every anchor is asserted before
# it is used; the script aborts rather than half-applying.
#
# THE PATTERN IT FOLLOWS is the one Supply/Exports already use:
#   * a module-local for the slider component, found by name
#   * Reset + SetProperty("Notify", Address) in the init block
#   * a branch in Notify() dispatching to an update function
#   * the update function repositions the entries with MoveTo
#
# WHAT IS DIFFERENT
#   Supply/Exports scroll a list of entries the script itself created, so it
#   knows their spacing (g_trade_entry_y_spacing). The World Market's slots
#   come from the LAYOUT, already positioned in a grid, and the script does not
#   know the grid. So the base positions are captured from the components on
#   the first ShowTrade and scrolling just offsets from those. That means the
#   script needs no knowledge of cols/rowheight and keeps working whatever grid
#   add_market_slot.rb produced.
#
# CLIPPING IS THE ENGINE'S JOB - once the slots are actually inside it
#   An earlier version of this patcher hid out-of-range slots by hand, with a
#   `g_market_visible_h = 20` fudge factor, because the slots appeared not to
#   be clipped. They were not clipped because add_market_slot.rb had made them
#   SIBLINGS of the display_window rather than children of it, so all three
#   rows drew across the panel and over the Supply heading below.
#
#   Vanilla's imports/exports look like they contradict that - their
#   display_window carries `children count="0"` - but only because those rows
#   are created at runtime with display_window:Address() as the parent.
#
#   reparent_market_slots.rb now moves the slots inside, so the engine clips
#   them for free and this script only has to MoveTo. No SetVisible, no
#   magic height.
#
# Usage
#   ruby patch_market_scroll.rb <government_screens.lua> [--apply]

path  = ARGV[0]
apply = ARGV.include?("--apply")
abort "usage: ruby patch_market_scroll.rb <government_screens.lua> [--apply]" unless path && File.file?(path)

src = File.read(path, mode: "rb")
src = src.sub(/\A\xEF\xBB\xBF/n, "")     # PowerShell BOM, if any
# Normalise to LF. The multi-line anchors below are written with \n, and a file
# that has been through PowerShell has CRLF - which silently fails to match.
src = src.gsub("\r\n", "\n")

if src.include?("market_slider")
  puts "already patched - nothing to do"
  exit 0
end

edits = []

# ---- 1. the component local, beside the other sliders ---------------------
anchor = %{local exports_slider = UIComponent(UIComponent(this:Find("exports")):Find("vslider"))}
abort "anchor 1 not found (exports_slider local)" unless src.include?(anchor)
src = src.sub(anchor, anchor + "\n" +
  %{local market_slider = UIComponent(UIComponent(this:Find("world market")):Find("vslider"))})
edits << "slider local"

# ---- 2. register for notifications, beside the others ---------------------
anchor = %{  exports_slider:LuaCall("Reset")\n  exports_slider:SetProperty("Notify", Address)}
abort "anchor 2 not found (exports_slider init)" unless src.include?(anchor)
src = src.sub(anchor, anchor + "\n" +
  %{  market_slider:LuaCall("Reset")\n  market_slider:SetProperty("Notify", Address)})
edits << "init/Notify registration"

# ---- 3. dispatch in Notify() ----------------------------------------------
anchor = %{  elseif notifier == exports_slider:Address() then\n    out.shane("Notify for exports_slider")\n    UpdateExportsSlider(value)}
abort "anchor 3 not found (Notify branch)" unless src.include?(anchor)
src = src.sub(anchor, anchor + "\n" +
  %{  elseif notifier == market_slider:Address() then\n    out.shane("Notify for market_slider")\n    UpdateMarketSlider(value)})
edits << "Notify branch"

# ---- 4. the state + update function ---------------------------------------
anchor = %{function UpdateExportsSlider(value)}
abort "anchor 4 not found (UpdateExportsSlider)" unless src.include?(anchor)
helper = <<~'LUA'
  g_market_slots = {}
  g_market_slider_max = 0
  function CaptureMarketSlots(window, prices)
    g_market_slots = {}
    local rows = {}
    for k, v in pairs(prices) do
      local c = window:Find(k)
      if c ~= nil then
        local comp = UIComponent(c)
        local x, y = comp:Position()
        table.insert(g_market_slots, {addr = c, x = x, y = y})
        rows[y] = true
      end
    end
    -- Derive the row pitch from the distinct row positions rather than being
    -- told it, so this keeps working whatever grid add_market_slot.rb laid
    -- out (8 per row today, something else tomorrow).
    local ys = {}
    for y in pairs(rows) do table.insert(ys, y) end
    table.sort(ys)
    local pitch = 0
    if #ys > 1 then
      pitch = ys[2] - ys[1]
    end
    local content = 0
    if #ys > 0 then
      content = ys[#ys] - ys[1] + pitch
    end
    -- The scrollable amount is content minus viewport, exactly as vanilla
    -- computes it for imports/exports (ShowTradeWindow's
    -- amount_larger_than_window). Using the row span alone overscrolls by one
    -- row's worth and leaves a blank pane at the bottom of the travel.
    local range = 0
    local dw = window:Find("display_window")
    if dw ~= nil then
      range = content - UIComponent(dw):Height()
    end
    if range < 0 then
      range = 0
    end
    g_market_slider_max = range
    out.shane("Captured " .. #g_market_slots .. " market slots in " .. #ys ..
              " row(s), pitch " .. pitch .. ", content " .. content ..
              ", scroll range " .. range)
  end
  function UpdateMarketSlider(value)
    -- CLAMP. The slider hands back whatever the handle was dragged to and
    -- nothing stops it exceeding the scrollable range. With a single row the
    -- range is 0, so every drag must be a no-op.
    if value == nil then value = 0 end
    if value < 0 then value = 0 end
    if value > g_market_slider_max then value = g_market_slider_max end
    for i = 1, #g_market_slots do
      local s = g_market_slots[i]
      -- MoveTo only: the slots are children of the display_window, so the
      -- engine clips whatever leaves the viewport.
      UIComponent(s.addr):MoveTo(s.x, s.y - value)
    end
  end
LUA
src = src.sub(anchor, helper + anchor)
edits << "CaptureMarketSlots + UpdateMarketSlider"

# ---- 5. drive it from ShowTrade -------------------------------------------
anchor = %{    for k, v in pairs(trade_info.price_changes) do}
abort "anchor 5 not found (ShowTrade price_changes loop)" unless src.include?(anchor)
src = src.sub(anchor,
  %{    if #g_market_slots == 0 then\n} +
  %{      CaptureMarketSlots(window, trade_info.prices)\n} +
  %{    end\n} +
  %{    market_slider:SetProperty("maxValue", g_market_slider_max)\n} +
  %{    market_slider:LuaCall("Reset")\n} +
  %{    UpdateMarketSlider(0)\n} + anchor)
edits << "ShowTrade wiring"

puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
edits.each_with_index { |e, i| puts "  #{i + 1}. #{e}" }
puts "size: #{File.size(path)} -> #{src.bytesize} bytes"

if apply
  # UTF-8 WITHOUT a BOM: loadstring dies with "unexpected symbol near '?'" on a BOM.
  File.write(path, src, mode: "wb")
  puts "\nNEXT: recompile with the game's own Lua (loadstring + string.dump via ESE)."
end
