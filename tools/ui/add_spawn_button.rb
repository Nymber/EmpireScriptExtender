# add_spawn_button.rb - clone a campaign HUD button into a spawn control.
#
# A click only fires if the component carries a script AND an event pair.
# CreateComponentFromTemplate cannot attach either, so the spawn control has
# to be a layout component. button_diplomacy is already in this file, so this
# is a sibling clone, not a foreign-template clone (those crash).
#
# The click runs OnSelect in THIS component's state. It cannot call a
# function that was defined somewhere else, so the toggle lives in the
# button. This is the version that was packed and tested: it opens and
# closes dialogue_box. A stock-tab flag is a different button, not this one.
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

SCRIPT = <<~'LUA'
function OnSelect()
	local pm = require('Utilities').Require('panelmanager')
	if pm.IsPanelOpen('dialogue_box') then
		pm.ClosePanel('dialogue_box')
	else
		pm.OpenPanel('dialogue_box', false, 'Initialise', 'UI kit')
	end
end
LUA

doc = UILayout.load(src)
abort "#{NAME} already present" if UILayout.find_named(doc, NAME)
raise "no button_diplomacy to clone" unless UILayout.find_named(doc, "button_diplomacy")

btn = UILayout.clone_named(doc, "button_diplomacy", NAME, SHIFT)
UILayout.set_xy!(btn, X, Y)

btn.xpath("./unicode")[0].content = "UI kit"
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
