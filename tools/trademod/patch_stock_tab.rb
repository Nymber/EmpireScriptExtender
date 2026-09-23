# patch_stock_tab.rb - teach government_screens.lua to drive the Stock
# Controls tab added by add_stock_tab.rb.
#
# The tab itself needs no script support: the panel registers tabs from the
# layout, and SelectTab shows/hides child 0. What is needed is the handler the
# tab's inline script calls -
#
#     function Select()
#       Component.Call("Parent.Parent.LuaCall", "ShowStockControls")
#     end
#
# - plus a reader for the stockpile.
#
# CROSS-STATE: stock lives in the CAMPAIGN lua_State and this panel runs in
# the UI one; they cannot call each other. Both have io, so chain_stock.lua is
# the shared state. chain_sim writes it each turn; this reads it.
#
# Run AFTER patch_market_labels.rb - this uses the tables it injects
# (g_market_dbkey, g_market_tooltips, g_chain_stock_path, g_chain_faction).
#
# Usage
#   ruby patch_stock_tab.rb <government_screens.lua> [--apply]

path  = ARGV[0]
apply = ARGV.include?("--apply")
abort "usage: ruby patch_stock_tab.rb <government_screens.lua> [--apply]" unless path && File.file?(path)

src = File.read(path, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").gsub("\r\n", "\n")

if src.include?("function ShowStockControls")
  puts "already patched - nothing to do"
  exit 0
end
unless src.include?("g_market_dbkey")
  abort "patch_market_labels.rb must run first - g_market_dbkey is missing"
end

helper = [
  %{-- Read the stockpile chain_sim maintains. Returns an empty table rather},
  %{-- than failing: an empty Stock tab is survivable, an error in a panel},
  %{-- handler is not.},
  %{function ReadChainStock()},
  %{  local t = {}},
  %{  local f = io.open(g_chain_stock_path, "rb")},
  %{  if f == nil then return t end},
  %{  local src = f:read("*a")},
  %{  f:close()},
  %{  local chunk = loadstring("return " .. src)},
  %{  if chunk == nil then return t end},
  %{  local ok, v = pcall(chunk)},
  %{  if ok and type(v) == "table" then return v end},
  %{  return t},
  %{end},
  %{},
  %{-- The Stock Controls tab. Same 23-slot grid as the World Market, but the},
  %{-- number under each icon is the TARGET - how much to hold back before},
  %{-- releasing any to trade - and the tooltip says what is actually in store.},
  %{function ShowStockControls()},
  %{  if SelectTab("stock") then},
  %{    local window = UIComponent(this:Find("stock market"))},
  %{    if window == nil then return end},
  %{    local stock = ReadChainStock()},
  %{    for uiname, dbkey in pairs(g_market_dbkey) do},
  %{      local slot = window:Find("stk_" .. uiname)},
  %{      if slot ~= nil then},
  %{        local have = stock["chain_" .. g_chain_faction .. "_" .. dbkey] or 0},
  %{        local want = stock["target_" .. g_chain_faction .. "_" .. dbkey] or 0},
  %{        local c = UIComponent(slot)},
  %{        local v = c:Find("dy_value")},
  %{        if v ~= nil then UIComponent(v):SetStateText(tostring(want)) end},
  %{        local ga = c:Find("growth_arrow")},
  %{        if ga ~= nil then UIComponent(ga):SetVisible(false) end},
  %{        local tip = g_market_tooltips[uiname] or uiname},
  %{        if want > 0 then},
  %{          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..},
  %{                           "\\nHolding back until: " .. want)},
  %{        else},
  %{          c:SetTooltipText(tip .. "\\n\\nIn store: " .. have ..},
  %{                           "\\nSelling everything produced")},
  %{        end},
  %{      end},
  %{    end},
  %{  end},
  %{end},
  %{},
].join("\n")

anchor = "function ShowTrade()"
abort "anchor not found (ShowTrade)" unless src.include?(anchor)
src = src.sub(anchor, helper + anchor)

puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
puts "  ReadChainStock()    - shared-state reader"
puts "  ShowStockControls() - drives SelectTab(\"stock\") and the 23 stk_ slots"
puts "size: #{File.size(path)} -> #{src.bytesize} bytes"

if apply
  File.write(path, src, mode: "wb")   # no BOM: loadstring dies on one
  puts "\nNEXT: recompile with the game's own Lua (loadstring + string.dump via ESE)."
end
