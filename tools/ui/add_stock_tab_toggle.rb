# add_stock_tab_toggle.rb - add a persistent header control that shows or hides
# the Stock Controls tab on the government screen.
#
# The control is a slim clone of tab_stock, placed directly under
# government_screens rather than inside tab_group. The panel's tab registrar
# therefore does not mistake it for another content tab, and it remains
# reachable while tab_stock is hidden. Its content pane is removed from the
# clone so the 23-row grid and its input controls are not duplicated.
#
# Usage
#   ruby add_stock_tab_toggle.rb <government_screens.xml> <out.xml>

require_relative "ui_layout"

src, dst = ARGV
abort "usage: add_stock_tab_toggle.rb <government_screens.xml> <out.xml>" unless src && dst && File.file?(src)

NAME = "button_stock_toggle"
ID_SHIFT = 0x01000000
X = 470
Y = 20

SCRIPT = <<~'LUA'
  local stock_tab_hidden = false
  local this = UIComponent(Address)

  function Select()
    if this == nil then return end
    local panel_address = this:Parent("government_screens")
    if panel_address == nil then return end
    local panel = UIComponent(panel_address)
    if panel == nil then return end
    local tab_address = panel:Find("tab_stock")
    if tab_address == nil then return end
    local tab = UIComponent(tab_address)
    if tab == nil then return end

    if stock_tab_hidden then
      local ok = pcall(function() tab:SetVisible(true) end)
      if ok then stock_tab_hidden = false end
    else
      -- Leave the panel on a valid visible tab before hiding the selected one.
      local ok = pcall(function() panel:LuaCall("ShowTrade") end)
      if not ok then return end
      local hidden = pcall(function() tab:SetVisible(false) end)
      if hidden then stock_tab_hidden = true end
    end
  end
LUA

doc = UILayout.load(src)
abort "#{NAME} already present" if UILayout.find_named(doc, NAME)

stock_tab = UILayout.find_named(doc, "tab_stock")
panel = UILayout.find_named(doc, "government_screens")
abort "no tab_stock to toggle" unless stock_tab
abort "no government_screens panel" unless panel
abort "tab_stock is not managed by tab_group" unless
  stock_tab.ancestors.any? { |n| n.name == "uientry" && UILayout.name_of(n) == "tab_group" }

button = stock_tab.dup
UILayout.reid!(button, ID_SHIFT)
button.xpath("./s").first.content = NAME
UILayout.set_xy!(button, X, Y)

# Keep the title and tab artwork, but drop the storage grid from the clone.
children = button.xpath("./children").first
abort "tab_stock clone has no children" unless children
content = children.xpath("./uientry").find { |e| UILayout.name_of(e) == "stock market" }
title = children.xpath("./uientry").find { |e| UILayout.name_of(e) == "tab_title" }
abort "tab_stock clone lacks stock market/title children" unless content && title
content.remove

# Preserve the proven Stock Controls localization ID, and make the button's
# hover text describe its persistent show/hide role.
root_tips = button.xpath("./unicode")
abort "toggle has #{root_tips.size} component tooltip fields, expected 2" unless root_tips.size == 2
root_tips[0].content = "Click to show or hide the Stock Controls tab."
root_tips[1].content = ""
title.xpath("./states/state").each do |state|
  fields = state.xpath("./unicode")
  abort "tab_title state has #{fields.size} text fields, expected 5" unless fields.size == 5
  fields[1].content = "Show or hide Stock Controls"
  fields[4].content = ""
end

script = button.xpath("./s").find do |field|
  next false unless field.next_sibling
  marker = field.next_sibling
  marker = marker.next_sibling while marker && marker.text? && marker.text.strip.empty?
  marker && marker.comment? && marker.text.strip == "script"
end
abort "tab_stock clone has no inline script" unless script
script.content = SCRIPT

events = button.xpath("./events/event/s").map(&:text)
abort "unexpected toggle events: #{events.inspect}" unless events == ["OnMouseLClickUp", "Select"]

root_children = panel.xpath("./children").first
abort "government_screens has no children" unless root_children
root_children.add_child(button)
fixed = UILayout.recompute_counts!(doc)

# Structural checks prevent the most common UI layout failures before packing.
abort "tab_stock was removed" unless UILayout.find_named(doc, "tab_stock")
abort "toggle accidentally entered tab_group" if
  button.ancestors.any? { |n| n.name == "uientry" && UILayout.name_of(n) == "tab_group" }
abort "toggle duplicates the stock grid" unless button.xpath(".//uientry").none? { |e| UILayout.name_of(e) == "stock market" }
ids = doc.xpath("//uientry/u").map { |u| u.text.to_i }
abort "duplicate component IDs after clone" unless ids.uniq.size == ids.size
abort "stale children count" if doc.xpath("//children").any? { |c| c["count"].to_i != c.xpath("./uientry").size }

UILayout.save(doc, dst)
verify = UILayout.load(dst)
abort "saved toggle missing" unless UILayout.find_named(verify, NAME)
abort "saved toggle lost callback" unless UILayout.find_named(verify, NAME).to_s.include?("stock_tab_hidden")

puts "added #{NAME} at #{X},#{Y} under government_screens"
puts "  tab_stock remains in tab_group; toggle is outside the tab manager"
puts "  stock market content is not duplicated"
puts "  corrected #{fixed} children counts; component IDs are unique"
puts "wrote #{dst}"
