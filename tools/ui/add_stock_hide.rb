# A Hide button on the Stock Controls pane.
#
# The HUD button and this panel are different Lua states, so they share a
# file: EmpireScriptExtender\lua\chain_tab.lua. "0" hides the tab, anything
# else (including a missing file) shows it. This button writes "0", hides
# the tab, and switches to Trade so the stock grid does not stay up.
#
# The click runs in THIS component's state. Do not LuaCall a panel function
# that was never added to government_screens.luac, and do not leave the
# donor's GovernmentPopupClose callback or the clone closes the panel.
#
# Run: ruby add_stock_hide.rb <government_screens.xml> <out.xml>

require_relative "ui_layout"

src, dst = ARGV
abort "usage: ruby add_stock_hide.rb <in.xml> <out.xml>" unless src && dst

NAME = "button_hide_stock"
SHIFT = 90000
# stock market is 566 wide. Sit inside the pane, clear of the first row.
X = 520
Y = 6

SCRIPT = <<~'LUA'
function OnSelect()
	local f = io.open([[D:\steam\steamapps\common\Empire Total War\EmpireScriptExtender\lua\chain_tab.lua]], "wb")
	if f then f:write("0") f:close() end
	local panel = UIComponent(this:Parent("government_screens"))
	local tab = UIComponent(panel:Find("tab_stock"))
	tab:SetVisible(false)
	panel:LuaCall("ShowTrade")
end
LUA

doc = UILayout.load(src)
abort "#{NAME} already present" if UILayout.find_named(doc, NAME)
pane = UILayout.find_named(doc, "stock market")
raise "no stock market pane" unless pane
donor = UILayout.find_named(doc, "government_screen_button_close")
raise "no close button to clone" unless donor

btn = donor.dup
UILayout.reid!(btn, SHIFT)
btn.xpath("./s").first.content = NAME
UILayout.set_xy!(btn, X, Y)

tips = btn.xpath("./unicode")
raise "hide button has #{tips.size} tooltip fields" unless tips.size >= 2
tips[0].content = "Hide Stock Controls"
tips[1].content = ""

# xml2ui labels the script field with a comment. The close button's script
# is empty, and so is its parent-name field, so an empty-text search writes
# the click into the parent name and the callback never runs.
scr = btn.xpath("./s").find { |s| s.next_sibling && s.next_sibling.comment? && s.next_sibling.text.include?("script") }
raise "cloned button has no script field" unless scr
scr.content = SCRIPT

events = btn.xpath("./events/event/s")
raise "expected a click pair, got #{events.size}" unless events.size == 2
raise "donor click is #{events[0].text}" unless events[0].text == "OnMouseLClickUp"
events[1].content = "OnSelect"

kids = pane.xpath("./children").first
raise "stock market has no children" unless kids
kids.add_child(btn)
UILayout.recompute_counts!(doc)
UILayout.save(doc, dst)

back = UILayout.load(dst)
got = UILayout.find_named(back, NAME)
raise "round trip lost #{NAME}" unless got
raise "callback still closes the panel" if got.to_xml.include?("GovernmentPopupClose")
raise "script lost" unless got.to_xml.include?("chain_tab.lua")
x, y = UILayout.xy(got)
puts "hide button: #{NAME} at #{x},#{y} inside stock market (id +#{SHIFT})"
