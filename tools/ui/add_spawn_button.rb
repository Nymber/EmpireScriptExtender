# add_spawn_button.rb - clone a campaign HUD button into a spawn control.
#
# A click only fires if the component carries a script AND an event pair.
# CreateComponentFromTemplate cannot attach either, so the spawn control has
# to be a layout component. button_diplomacy is already in this file, so this
# is a sibling clone, not a foreign-template clone (those crash).
#
# The click runs OnSelect in THIS component's state. It cannot see the
# government panel, so it writes chain_tab.lua ("1" = show the stock tab).
# The government panel reads that file on its own pulse and on Initialise.
#
# Usage
#   ruby add_spawn_button.rb <layout.xml> <out.xml>

require_relative "ui_layout"

src, dst = ARGV
abort "usage: add_spawn_button.rb <layout.xml> <out.xml>" unless src && dst

SHIFT = 80_000
NAME  = "ese_ui_spawn"
# orders layout is 310 wide. The 60px row ends at x=278. This sits just
# past it, still inside the cluster, and clear of end-turn (200,52 80x80).
X = 282
Y = 151

# Writes the shared flag the government panel reads. This state cannot see
# the stock tab, so it does not call SetVisible or OpenPanel.
SCRIPT = <<~'LUA'
function OnSelect()
	local f = io.open([[D:\steam\steamapps\common\Empire Total War\EmpireScriptExtender\lua\chain_tab.lua]], "wb")
	if f then f:write("1") f:close() end
end
LUA

doc = UILayout.load(src)
abort "#{NAME} already present" if UILayout.find_named(doc, NAME)
raise "no button_diplomacy to clone" unless UILayout.find_named(doc, "button_diplomacy")

btn = UILayout.clone_named(doc, "button_diplomacy", NAME, SHIFT)
UILayout.set_xy!(btn, X, Y)

btn.xpath("./unicode")[0].content = "Show Stock Controls"
btn.xpath("./unicode")[1].content = ""

scr = btn.xpath("./s").find { |s| s.text.include?("function ") }
raise "cloned button has no script" unless scr
scr.content = SCRIPT

ev = btn.xpath("./events").first
raise "cloned button has no events" unless ev
ev.children.each(&:remove)
[["OnMouseLClickUp", nil], ["OnSelect", nil]].each do |name, _|
  e = Nokogiri::XML::Node.new("event", doc)
  s = Nokogiri::XML::Node.new("s", doc)
  s.content = name
  e.add_child(s)
  ev.add_child(e)
end

# The diplomacy art stays. A literal caption would need a loc key to win,
# and these buttons are drawn from their TGA, so the art is the label.
UILayout.recompute_counts!(doc)
UILayout.save(doc, dst)

puts "spawn button: #{NAME} at #{X},#{Y} (cloned button_diplomacy, id +#{SHIFT})"
puts "wrote #{dst}"
