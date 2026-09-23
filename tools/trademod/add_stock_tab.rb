# add_stock_tab.rb - add a "Stock Controls" tab beside Trade on the government
# screen, for setting how much of each commodity to hold back from trade.
#
# WHY A TAB IS CHEAP HERE
#   The panel script registers tabs from the LAYOUT, not from a list:
#
#     for i = 0, tabgroup:ChildCount() - 1 do
#       local tab = UIComponent(tabgroup:Find(i))
#       local sub_id = string.sub(tab:Id(), s_end + 1)   -- "tab_trade" -> "trade"
#       tabs[sub_id] = tab
#     end
#
#   so a component called `tab_stock` is picked up automatically, and
#   SelectTab("stock") shows/hides its CHILD 0 as the content panel. Each tab
#   carries an inline script that routes the click:
#
#     function Select()
#       Component.Call("Parent.Parent.LuaCall", "ShowTrade")
#     end
#
#   and the label is a plain <unicode> field, not a loc key.
#
# WHAT IT CLONES
#   tab_trade, because it is the tab we understand. Its content child (the
#   whole trade screen) is replaced with a clone of the World Market pane -
#   already a scrollable grid of 23 commodity slots with icons, which is
#   exactly the shape a stock screen wants. Slots are renamed stk_<good> so
#   Find() cannot collide with the real market's, since Find is RECURSIVE.
#
# Usage
#   ruby add_stock_tab.rb <in.xml> <out.xml> [--x N] [--apply]

require "nokogiri"

src, dst = ARGV[0], ARGV[1]
apply = ARGV.include?("--apply")
def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1].to_i : d
end
tab_x = opt("x", 457)          # tab_trade sits at 342 and is 115 wide
ID_SHIFT = 0x00A40000          # keep cloned component ids clear of everything

abort "usage: ruby add_stock_tab.rb <in.xml> <out.xml> [--x N] [--apply]" unless src && dst && File.file?(src)

doc = Nokogiri::XML(File.read(src, mode: "rb"))
def name_of(e) = (s = e.xpath("./s").first) ? s.text : ""
def find_named(doc, n) = doc.xpath("//uientry").find { |e| name_of(e) == n }

tab_trade = find_named(doc, "tab_trade")
market    = find_named(doc, "world market")
abort "no tab_trade in this layout"    unless tab_trade
abort "no 'world market' pane"         unless market
abort "tab_stock already present"      if find_named(doc, "tab_stock")

tabgroup = tab_trade.parent
while tabgroup && tabgroup.name != "children" do tabgroup = tabgroup.parent end
abort "tab_trade is not inside a <children> array" unless tabgroup

# ---- clone, giving every component a fresh id ------------------------------
def reid!(node, shift)
  node.xpath(".//u | ./u").each do |u|
    # Inside an <image_use> only the FIRST <u> is an id; the rest are x/y/w/h,
    # stored unsigned - so a negative offset looks like a huge id and gets
    # renumbered into nonsense. Harmless for this pane (its offsets are all
    # under the 0x1000 threshold) but wrong, and it bit the text input.
    if u.parent.name == "image_use"
      next unless u.parent.xpath("./u").first.equal?(u)
    end
    v = u.text.to_i
    u.content = (v + shift).to_s if v > 0x1000
  end
end

tab = tab_trade.dup
reid!(tab, ID_SHIFT)

# name + position
tab.xpath("./s").first.content = "tab_stock"
ti = tab.xpath("./i")
ti[0].content = tab_x.to_s

# the inline script is what routes the click
scr = tab.xpath("./s").find { |s| s.text.include?("Component.Call") }
abort "tab_trade has no inline Select() script - layout differs from expectations" unless scr
scr.content = scr.text.gsub("ShowTrade", "ShowStockControls")

# LABEL. The caption is NOT on tab_trade itself - all five of its text fields
# are empty in both states. It lives on a CHILD component called `tab_title`,
# whose single state carries five <unicode> fields in this fixed order:
#
#     [0] state text        "Trade"
#     [1] tooltip           ""
#     [2] text label        ""
#     [3] localization id   "tab_title_NewState_Text_160050"
#     [4] tooltip id        ""
#
# Two traps, both hit:
#   - Indexing [0]/[1] as (text, id) writes the TOOLTIP, not the id. The
#     literal text changed and the caption did not, which looks like the edit
#     silently failing when it actually landed one field over.
#   - THE LOCALISATION ID WINS over the literal text, and that id resolves in
#     `text/ui.loc` - NOT localisation.loc, where it does not exist at all.
#     So the new key must ship in the mod's ui.loc (build_localisation.rb
#     --which ui), or this tab renders blank instead of "Stock Controls".
LOC_KEY  = "tab_title_NewState_Text_stock_controls"
F_TEXT   = 0
F_LOCID  = 3
label_set = false
title = tab.xpath(".//uientry").find { |e| name_of(e) == "tab_title" }
abort "cloned tab has no `tab_title` child - layout differs from expectations" unless title
title.xpath("./states/state").each do |st|
  us = st.xpath("./unicode")
  # Guard the field count: silently writing index 3 of a 2-field state would
  # corrupt a different component rather than fail.
  abort "tab_title state has #{us.size} text fields, expected 5" unless us.size == 5
  us[F_TEXT].content  = "Stock Controls"
  us[F_LOCID].content = LOC_KEY
  label_set = true
end
warn "WARNING: no tab-title state found - the caption will stay 'Trade'" unless label_set

# ---- child 0 becomes a clone of the World Market pane ----------------------
kids = tab.xpath("./children").first
abort "cloned tab has no <children>" unless kids
old_content = kids.xpath("./uientry").first
abort "cloned tab has no content child" unless old_content

# POSITION. `world market` was nested inside tab_trade's content child, so its
# x/y were relative to THAT. Dropping it straight under the tab kept
# coordinates meant for a different parent, which is why the pane floated off
# to the right with only one slot visible. Rebase so the clone lands exactly
# where the Trade tab's market appears:
#     new = (tab_trade + old_content + market) - tab_stock
def xy_of(e)
  i = e.xpath("./i")
  [i[0].text.to_i, i[1].text.to_i]
end
tt_x, tt_y = xy_of(tab_trade)
oc_x, oc_y = xy_of(old_content)
mk_x, mk_y = xy_of(market)
new_x = (tt_x + oc_x + mk_x) - tab_x
new_y = (tt_y + oc_y + mk_y) - 0

pane = market.dup
reid!(pane, ID_SHIFT + 0x1000)
pane.xpath("./s").first.content = "stock market"
pi = pane.xpath("./i")
pi[0].content = new_x.to_s
pi[1].content = new_y.to_s
# Find() is recursive, so every slot needs a name the real market does not use
renamed = 0
dw = pane.xpath("./children/uientry").find { |e| name_of(e) == "display_window" }
(dw ? dw.xpath("./children/uientry") : []).each do |slot|
  s = slot.xpath("./s").first
  next unless s
  s.content = "stk_" + s.text
  renamed += 1
end
old_content.replace(pane)

tabgroup.add_child(tab)

# ---- counts, because xml2ui writes them verbatim ---------------------------
fixed = 0
doc.xpath("//children").each do |c|
  real = c.xpath("./uientry").size.to_s
  next if c["count"] == real
  c["count"] = real
  fixed += 1
end

puts "cloned tab_trade -> tab_stock at x=#{tab_x}"
puts "  label            : #{label_set ? 'Stock Controls' : '(UNCHANGED - check)'}"
puts "  content pane     : world market -> stock market"
puts "  slots renamed    : #{renamed} (stk_ prefix, so Find cannot collide)"
puts "  children counts corrected: #{fixed}"
puts "  tabs in group now: #{tabgroup.xpath('./uientry').size}"

if apply
  File.write(dst, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML), mode: "wb")
  puts "\nwritten: #{dst}"
else
  puts "\nDRY RUN (pass --apply to write)"
end
