# add_dialogue_scroll.rb - give the shared dialogue_box a vertical scrollbar,
# so a long message (the per-turn chain report) can be read in full.
#
# WHY THE BOX DOES NOT GET BIGGER
#   dialogue_box is shared: advisor messages AND the OK/Cancel confirmations
#   use it. Resizing it moves `ok_group` and `both_group` and changes every
#   dialogue in the game. So the frame stays exactly 488x320 and all the
#   surgery happens INSIDE `text_panel`, which nothing else measures.
#
# WHY A CLONED WINDOW RATHER THAN text_panel ITSELF
#   Clipping is a property of the component TYPE, not a flag we can set:
#       display_window / vslider  type 10
#       text_panel / DY_text      type 60   (plain, never clips)
#   A type-60 parent will happily draw its child outside its own bounds, so
#   moving DY_text to scroll it would just slide visible text over the frame.
#   The clipping window and the slider are therefore CLONED out of
#   government_screens, which has known-good type-10 components.
#
# WHY DY_text GETS TALLER
#   Text is drawn centred inside its own component and clipped by it, so a
#   172px-tall DY_text can only ever show 172px of text no matter where it is
#   moved. Growing it gives the text room to lay out; the new clipping window
#   is what keeps it inside the frame, and the script scrolls it with MoveTo -
#   the same mechanism proven on the World Market.
#
# Usage
#   ruby add_dialogue_scroll.rb <dialogue.xml> <out.xml> [--donor F] [--apply]

require "nokogiri"

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
src, dst = ARGV[0], ARGV[1]
apply = ARGV.include?("--apply")
donor_path = opt("donor",
  "C:/Users/ellis/AppData/Local/Temp/claude/D--steam-steamapps-common-Empire-Total-War/" \
  "d2975cc5-f82c-4cd3-a2ab-bd17485094c6/scratchpad/gs_base.xml")
abort "usage: ruby add_dialogue_scroll.rb <in.xml> <out.xml> [--apply]" unless src && dst && File.file?(src)
abort "no donor layout at #{donor_path}" unless File.file?(donor_path)

TEXT_W, TEXT_H = 407, 172        # DY_text's current size, i.e. the viewport
SLIDER_W       = 12
VIEW_W         = TEXT_W - SLIDER_W - 4
TALL           = 1200            # room for the text to lay out into
ID_SHIFT       = 0x00C00000

doc   = Nokogiri::XML(File.read(src, mode: "rb"))
donor = Nokogiri::XML(File.read(donor_path, mode: "rb"))
def name_of(e) = (s = e.xpath("./s").first) ? s.text : ""
def find_named(d, n) = d.xpath("//uientry").find { |e| name_of(e) == n }

panel = find_named(doc, "text_panel")
text  = find_named(doc, "DY_text")
abort "no text_panel in this layout"  unless panel
abort "no DY_text in this layout"     unless text
abort "already patched"               if find_named(doc, "dlg_window")

$seq = 0
def reid!(node, shift)
  $seq += 1
  node.xpath(".//u | ./u").each do |u|
    # image_use holds geometry in <u> after the first entry - never renumber it
    if u.parent.name == "image_use"
      next unless u.parent.xpath("./u").first.equal?(u)
    end
    v = u.text.to_i
    u.content = (v + shift + $seq * 0x40).to_s if v > 0x1000
  end
end
def set_pos(e, x, y)
  i = e.xpath("./i"); i[0].content = x.to_s; i[1].content = y.to_s
end
def set_size(e, w, h)
  e.xpath("./states/state").each do |st|
    si = st.xpath("./i")
    next if si.size < 2
    si[0].content = w.to_s; si[1].content = h.to_s
  end
end

win_src = find_named(donor, "display_window")
sld_src = find_named(donor, "vslider")
abort "donor has no display_window" unless win_src
abort "donor has no vslider"        unless sld_src

# --- the clipping viewport, as a sibling of DY_text inside text_panel -------
win = win_src.dup
reid!(win, ID_SHIFT)
win.xpath("./s").first.content = "dlg_window"
set_pos(win, 11, 11)                            # where DY_text used to sit
set_size(win, VIEW_W, TEXT_H)

# REUSE the donor's <children> node, do not build one. A uientry's fields are
# positional and xml2ui writes them in document order, so a hand-made
# <children> appended at the end lands after <states> and the template - the
# reader then takes some other field as the child count and reports
# "children array element count of 65536 impossibly high". Emptying the
# existing node keeps everything in its correct slot.
win_kids = win.xpath("./children").first
abort "donor display_window has no <children> node to reuse" unless win_kids
win_kids.xpath("./uientry").each(&:remove)

# --- move DY_text inside it, and give it room to lay out --------------------
text.unlink
set_pos(text, 0, 0)
set_size(text, VIEW_W, TALL)
win_kids.add_child(text)

# --- the slider -------------------------------------------------------------
sld = sld_src.dup
reid!(sld, ID_SHIFT + 0x10000)
sld.xpath("./s").first.content = "dlg_slider"
set_pos(sld, 11 + VIEW_W + 2, 11)
set_size(sld, SLIDER_W, TEXT_H)

pkids = panel.xpath("./children").first
unless pkids
  pkids = Nokogiri::XML::Node.new("children", doc)
  panel.add_child(pkids)
end
pkids.add_child(win)
pkids.add_child(sld)

# counts are written verbatim by xml2ui
fixed = 0
doc.xpath("//children").each do |c|
  real = c.xpath("./uientry").size.to_s
  next if c["count"] == real
  c["count"] = real
  fixed += 1
end

box = find_named(doc, "dialogue_box")
bs  = box.xpath("./states/state").first.xpath("./i")
puts "dialogue_box   : #{bs[0].text} x #{bs[1].text}  (UNCHANGED - confirmations unaffected)"
puts "dlg_window     : #{VIEW_W} x #{TEXT_H} at 11,11   (type 10, clips)"
puts "DY_text        : #{VIEW_W} x #{TALL}, now a child of dlg_window"
puts "dlg_slider     : #{SLIDER_W} x #{TEXT_H} at #{11 + VIEW_W + 2},11"
puts "children counts corrected: #{fixed}"

if apply
  File.write(dst, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML), mode: "wb")
  puts "\nwritten: #{dst}"
else
  puts "\nDRY RUN (pass --apply to write)"
end
