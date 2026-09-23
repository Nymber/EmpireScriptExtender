# build_stock_panel.rb - turn the Stock Controls tab from a copy of the narrow
# World Market strip into a full-panel grid with a real checkbox per commodity.
#
# WHAT WAS WRONG
#   add_stock_tab.rb cloned the World Market pane, which is 566x94 - a single
#   scrolling row. Dropped into a 624x720 panel that leaves ~580px of dead
#   white space below it.
#
# THE GEOMETRY (measured, not guessed)
#   government_screens  624 x 720
#   tab_group           at y=68, h=28        -> tabs end at y=96
#   stock market        at tab-relative y=43 -> panel-relative y=111
#   so the usable content box is 566 wide and ~585 tall.
#
# THE LAYOUT
#   2 columns x 12 rows = 24 cells for 23 commodities, pitch 44. Every row:
#
#     [icon 26]  [name]         [target]  [x]
#      slot      stk_name       dy_value  stk_check
#
#   name and checkbox are added as CHILDREN OF THE SLOT, so their coordinates
#   are slot-relative and a row moves as one unit.
#
# THE CHECKBOX IS VANILLA'S. This panel already has two (automanage taxes and
# construction): 22x22, nine states, and the full checkbox*.tga art. Cloning it
# means the art, the hover states and the selected state all work for free.
# Its protocol, from the panel's own Notify():
#     value == "down"          -> the box was just TICKED
#     value == "selected_down" -> the box was just UNTICKED
#
# NAME COLLISIONS ARE SAFE. The cloned pane duplicates `header`,
# `display_window` and `vslider`, and Find IS recursive - but every existing
# lookup scopes to a pane first (`this:Find("world market"):Find("vslider")`),
# so none of them can reach into this clone. Verified before resizing.
#
# Usage
#   ruby build_stock_panel.rb <in.xml> <out.xml> [--apply]

require "nokogiri"

src, dst = ARGV[0], ARGV[1]
apply = ARGV.include?("--apply")
abort "usage: ruby build_stock_panel.rb <in.xml> <out.xml> [--apply]" unless src && dst && File.file?(src)

# ---- geometry --------------------------------------------------------------
PANE_W, PANE_H = 566, 585
DW_X, DW_Y     = 11, 28
DW_W, DW_H     = 520, PANE_H - DW_Y - 12
COLS, PITCH    = 2, 44
COL_W          = DW_W / COLS            # 260
ICON_X, ICON_Y = 4, 4
# The name column was 76px, which clipped "Ammunition" (it rendered as
# ".mmunition" - the label centres its text, so an overlong string is cut at
# BOTH ends) and wrapped "Naval Supplies" onto a second line that the 18px
# height then cut off.
#
# SIZE IT FROM EVIDENCE, NOT A GUESS. "Ammunition" is 10 characters and did
# NOT fit 76px, so Ingame 14 averages more than 7.6px per character - an
# estimate of 7 would have sized this column at 104 and clipped the longest
# label again. At 8px/char the longest rendered label, "Naval Supplies" (14),
# needs 112. Row: 4+112 +26 +50 +22 = 252 inside a 260px column, 8px clear.
NAME_DX, NAME_DY, NAME_W, NAME_H = 32, 4, 112, 18
VAL_DX,  VAL_DY,  VAL_W,  VAL_H  = 146, 4, 26, 18
INP_DX,  INP_DY,  INP_W,  INP_H  = 176, -1, 50, 28
CHK_DX,  CHK_DY                  = 230, 2
ID_SHIFT = 0x00B00000

# The typed target field is cloned out of the SAVE GAME screen, which is where
# this game keeps its only text-entry component: `input_name`, whose behaviour
# comes from the `template.text_input.lua` named in its template field (its own
# script field is empty). The template gives typing, a caret, backspace/delete,
# arrows, home/end - and two hooks this needs:
#     SetGlobal("CharacterValidator", fn)  per-character filter -> digits only
#     SetGlobal("g_notify_func", fn)       fires on Enter/Escape/click-away
def opt_arg(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
DONOR = opt_arg("donor", File.join(
  "C:/Users/ellis/AppData/Local/Temp/claude/D--steam-steamapps-common-Empire-Total-War",
  "d2975cc5-f82c-4cd3-a2ab-bd17485094c6/scratchpad/inputs/lsg.xml"))

doc = Nokogiri::XML(File.read(src, mode: "rb"))
def name_of(e) = (s = e.xpath("./s").first) ? s.text : ""
def find_named(doc, n) = doc.xpath("//uientry").find { |e| name_of(e) == n }

pane = find_named(doc, "stock market")
abort "no 'stock market' pane - run add_stock_tab.rb first" unless pane

# A fresh id for every cloned component, or two components share an id and the
# engine's own lookups become ambiguous.
$id_seq = 0
def reid!(node, shift)
  $id_seq += 1
  node.xpath(".//u | ./u").each do |u|
    # NOT EVERY <u> IS AN ID. Inside an <image_use> only the first is; the
    # next four are x, y, w, h. Offsets are stored unsigned, so the text
    # input's left edge at -3 arrives as 4294967293 - comfortably over the
    # "looks like an id" threshold - and renumbering it moved that edge
    # eleven million pixels away. Geometry must never be reid'd.
    if u.parent.name == "image_use"
      next unless u.parent.xpath("./u").first.equal?(u)
    end
    v = u.text.to_i
    u.content = (v + shift + $id_seq * 0x40).to_s if v > 0x1000
  end
end

def set_pos(e, x, y)
  i = e.xpath("./i")
  i[0].content = x.to_s
  i[1].content = y.to_s
end

def set_size(e, w, h)
  e.xpath("./states/state").each do |st|
    si = st.xpath("./i")
    next if si.size < 2
    si[0].content = w.to_s
    si[1].content = h.to_s
  end
end

# A pane's border is a NINE-SLICE built from image_use entries, and resizing
# the state alone does not touch it: the frame kept the donor's 94px height,
# so the gold border stopped two rows down and the rest of the grid sat on
# bare panel background. Each entry is (x, y, w, h) laid out as
#
#     corner   top edge    corner        C = corner size (16 here)
#     left     centre      right         edges span W-2C / H-2C
#     corner   bottom      corner        bottom/right pinned at W-C / H-C
#
# Roles are derived from the ORIGINAL dimensions rather than assumed by index,
# so this keeps working if a donor pane has its pieces in another order.
def rescale_9slice!(e, w0, h0, w, h)
  pieces = e.xpath("./states/state/image_uses/image_use").select { |u| u.xpath("./u").size >= 5 }
  return 0 if pieces.empty?
  # ONE corner size for the whole frame, taken from the smallest piece - the
  # corners. Deriving it per piece as min(w,h) picks up the CENTRE panel's own
  # height (62) and rescales it as though the border were 62px thick, which
  # silently shrank the fill to 442x461 inside a 566x585 frame.
  c = pieces.map { |u| n = u.xpath("./u"); [n[3].text.to_i, n[4].text.to_i].min }.min
  c = 16 if c <= 0
  # Offsets are stored UNSIGNED, so the text input's left edge at -3 arrives as
  # 4294967293. Read it back as signed or every comparison below misfires.
  sgn = ->(v) { v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
  uns = ->(v) { v < 0 ? v + 0x1_0000_0000 : v }
  # Map only the values that ARE a function of the old size; leave the rest.
  # Two conventions exist in this game's frames and both must work:
  #   pane       edges inset by c, spanning size-2c, corners at 0 and size-c
  #   text input edges spanning the FULL size, sitting OUTSIDE at -c and size
  pos = ->(v, o, n) do
    case v
    when 0      then 0
    when -c     then -c
    when o      then n          # flush against the far edge
    when o - c  then n - c      # inset by one corner
    else v
    end
  end
  ext = ->(v, o, n) do
    case v
    when o         then n       # spans the whole side
    when o - 2 * c then n - 2 * c
    when o - c     then n - c
    else v
    end
  end
  moved = 0
  pieces.each do |u|
    n = u.xpath("./u")
    x, y = sgn.(n[1].text.to_i), sgn.(n[2].text.to_i)
    iw, ih = n[3].text.to_i, n[4].text.to_i
    nx, ny = pos.(x, w0, w), pos.(y, h0, h)
    nw, nh = ext.(iw, w0, w), ext.(ih, h0, h)
    next if [nx, ny, nw, nh] == [x, y, iw, ih]
    n[1].content, n[2].content = uns.(nx).to_s, uns.(ny).to_s
    n[3].content, n[4].content = nw.to_s, nh.to_s
    moved += 1
  end
  moved
end

# The cloned checkbox is the AUTOMANAGE TAXES box, so it carries that box's
# tooltip - hovering a commodity's checkbox explained how to manage taxes
# manually. Both the uientry-level pair and the per-state pair have to go, and
# the localisation ids especially: an id WINS over literal text, so blanking
# only the text would leave the tax string on screen.
def clear_tooltips!(e)
  us = e.xpath("./unicode")               # uientry: [0] tooltip text, [1] tooltip id
  us[0].content = "" if us[0]
  us[1].content = "" if us[1]
  e.xpath("./states/state").each do |st|
    su = st.xpath("./unicode")            # state: [1] tooltip, [4] tooltip id
    su[1].content = "" if su[1]
    su[4].content = "" if su[4]
  end
end

# The state's text is field [0] and its localisation id is field [3]; the id
# WINS at load. SetStateText overrides it at runtime, but blanking it here
# keeps the first painted frame from showing the donor's string.
def set_text(e, s, clear_locid: true)
  e.xpath("./states/state").each do |st|
    us = st.xpath("./unicode")
    next if us.size < 4
    us[0].content = s
    us[3].content = "" if clear_locid
  end
end

# ---- the pane itself -------------------------------------------------------
# Read the CURRENT size before changing it - the nine-slice has to be rescaled
# from whatever it actually is, not from an assumed 566x94.
pst = pane.xpath("./states/state").first.xpath("./i")
old_w, old_h = pst[0].text.to_i, pst[1].text.to_i
set_size(pane, PANE_W, PANE_H)
slices = rescale_9slice!(pane, old_w, old_h, PANE_W, PANE_H)

header = pane.xpath("./children/uientry").find { |e| name_of(e) == "header" }
set_text(header, "Stock Controls") if header

dw = pane.xpath("./children/uientry").find { |e| name_of(e) == "display_window" }
abort "pane has no display_window" unless dw
set_pos(dw, DW_X, DW_Y)
set_size(dw, DW_W, DW_H)

vs = pane.xpath("./children/uientry").find { |e| name_of(e) == "vslider" }
if vs
  # The grid fits without scrolling, so the slider would be a dead control.
  # Shrink it to nothing rather than deleting it: the pane's children array and
  # the panel's own structure stay exactly as cloned.
  set_size(vs, 0, 0)
end

# ---- donors ----------------------------------------------------------------
checkbox_src = doc.xpath("//uientry").find { |e| name_of(e) == "checkbox" }
abort "no vanilla 'checkbox' component to clone" unless checkbox_src

input_src = nil
input_w0 = input_h0 = nil
if File.file?(DONOR)
  ddoc = Nokogiri::XML(File.read(DONOR, mode: "rb"))
  input_src = ddoc.xpath("//uientry").find { |e| name_of(e) == "input_name" }
  if input_src
    ist = input_src.xpath("./states/state").first.xpath("./i")
    input_w0, input_h0 = ist[0].text.to_i, ist[1].text.to_i
    # The donor carries a caption child ("Name:") that makes no sense per row.
    # `highlight` must stay - template.text_input.lua calls SetVisible on it.
    input_src = input_src.dup
    input_src.xpath("./children/uientry").each do |c|
      c.remove if name_of(c) == "input_name_label"
    end
  end
end
abort "no text-input donor at #{DONOR} - extract load-save_game and ui2xml it first" unless input_src

slots = dw.xpath("./children/uientry").select { |e| name_of(e).start_with?("stk_") }
abort "no stk_ slots - add_stock_tab.rb must run first" if slots.empty?

label_src = slots.first.xpath("./children/uientry").find { |e| name_of(e) == "dy_value" }
abort "slot has no dy_value to clone for the name label" unless label_src

rows_needed = (slots.size / COLS.to_f).ceil
abort "#{rows_needed} rows at pitch #{PITCH} overflows the #{DW_H}px window" if 4 + rows_needed * PITCH > DW_H

# ---- lay out ---------------------------------------------------------------
added_names, added_checks, added_inputs = 0, 0, 0
slots.sort_by { |s| name_of(s) }.each_with_index do |slot, idx|
  good = name_of(slot).sub(/\Astk_/, "")
  col, row = idx % COLS, idx / COLS
  set_pos(slot, col * COL_W + ICON_X, row * PITCH + ICON_Y)

  kids = slot.xpath("./children").first
  abort "slot #{good} has no <children>" unless kids

  # the existing value text moves right and becomes the target readout
  if (dv = kids.xpath("./uientry").find { |e| name_of(e) == "dy_value" })
    set_pos(dv, VAL_DX, VAL_DY)
    set_size(dv, VAL_W, VAL_H)
  end
  # `coins` implies a price; this column is a quantity. Parked at zero size
  # rather than hidden in Lua, so it cannot flash on the first frame.
  if (cn = kids.xpath("./uientry").find { |e| name_of(e) == "coins" })
    set_size(cn, 0, 0)
  end
  if (ga = kids.xpath("./uientry").find { |e| name_of(e) == "growth_arrow" })
    set_size(ga, 0, 0)
  end

  unless kids.xpath("./uientry").any? { |e| name_of(e) == "stk_name" }
    lbl = label_src.dup
    reid!(lbl, ID_SHIFT)
    lbl.xpath("./s").first.content = "stk_name"
    set_pos(lbl, NAME_DX, NAME_DY)
    set_size(lbl, NAME_W, NAME_H)
    set_text(lbl, good)          # replaced with the real name at refresh
    kids.add_child(lbl)
    added_names += 1
  end

  unless kids.xpath("./uientry").any? { |e| name_of(e) == "stk_input" }
    inp = input_src.dup
    reid!(inp, ID_SHIFT + 0x40000)
    inp.xpath("./s")[0].content = "stk_input"
    inp.xpath("./s")[1].content = "stk_input" if inp.xpath("./s")[1]  # parent name
    clear_tooltips!(inp)
    set_pos(inp, INP_DX, INP_DY)
    set_size(inp, INP_W, INP_H)
    rescale_9slice!(inp, input_w0, input_h0, INP_W, INP_H)
    set_text(inp, "")
    kids.add_child(inp)
    added_inputs += 1
  end

  unless kids.xpath("./uientry").any? { |e| name_of(e) == "stk_check" }
    chk = checkbox_src.dup
    reid!(chk, ID_SHIFT + 0x20000)
    chk.xpath("./s").first.content = "stk_check"
    clear_tooltips!(chk)
    set_pos(chk, CHK_DX, CHK_DY)
    # Zero-argument-plus-state, exactly the vanilla checkbox protocol. The
    # commodity is baked into the function name so nothing has to be looked up
    # by address the way Notify() does it for the two automanage boxes.
    scr = chk.xpath("./s").find do |s|
      c = s.next_sibling
      c = c.next_sibling while c && c.text? && c.text.strip.empty?
      c && c.comment? && c.text.strip == "script"
    end
    abort "cloned checkbox has no script field" unless scr
    scr.content = [
      'local this = UIComponent(Address)',
      'local parent = UIComponent(this:Parent("government_screens"))',
      '',
      'function NotifySelected()',
      "\tparent:LuaCall(\"ToggleStock_#{good}\", Component.Call(\"CurrentState\"))",
      'end',
    ].join("\r\n")
    kids.add_child(chk)
    added_checks += 1
  end
end

# ---- counts, because xml2ui writes them verbatim ---------------------------
fixed = 0
doc.xpath("//children").each do |c|
  real = c.xpath("./uientry").size.to_s
  next if c["count"] == real
  c["count"] = real
  fixed += 1
end

puts "pane            : #{PANE_W} x #{PANE_H}  (was #{old_w} x #{old_h})"
puts "frame 9-slice   : #{slices} piece(s) rescaled"
puts "display_window  : #{DW_W} x #{DW_H} at #{DW_X},#{DW_Y}"
puts "grid            : #{COLS} cols x #{rows_needed} rows, pitch #{PITCH}, col width #{COL_W}"
puts "slots laid out  : #{slots.size}"
puts "name labels     : +#{added_names}"
puts "target inputs   : +#{added_inputs}  (template.text_input.lua)"
puts "checkboxes      : +#{added_checks}"
puts "children counts corrected: #{fixed}"

if apply
  File.write(dst, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML), mode: "wb")
  puts "\nwritten: #{dst}"
else
  puts "\nDRY RUN (pass --apply to write)"
end
