# align_market_viewport.rb - set the World Market scroll viewport's position,
# height and row pitch so exactly one whole row is visible.
#
# WHY A ROW IS 49px, NOT 26px
#   The icon is 26x26, but a slot's CHILDREN hang below it:
#     growth_arrow  y=28 h=18 -> 46
#     coins         y=31 h=15 -> 46
#     dy_value      y=31 h=18 -> 49   <- the price, the lowest thing drawn
#   So a row occupies 49px. add_market_slot.rb laid the grid out on a 46px
#   pitch, which is SMALLER than the row it is spacing: each row's price
#   overlapped the next row's icon, and with the viewport at 52px starting the
#   first row 12px down, the bottom 9px of every price was clipped away.
#
# WHAT IT SETS
#   display_window : (x, y) and w x height
#   vslider        : same y and height, its bar image_uses, and its `bottom`
#                    button (which sits at height - 1)
#   the slots      : row r moves to y = r * pitch, columns untouched
#
#   Height should be >= pitch and pitch >= 49, or something is clipped again.
#
# The scroll range is NOT set here - government_screens.lua derives it as
# content - display_window:Height() at runtime, so this tool and the script
# cannot disagree.
#
# Usage
#   ruby align_market_viewport.rb <in.xml> <out.xml> [--y N] [--height N]
#                                 [--pitch N] [--apply]

require "nokogiri"

src, dst = ARGV[0], ARGV[1]
apply    = ARGV.include?("--apply")
def opt(name, default)
  i = ARGV.index("--#{name}")
  i && ARGV[i + 1] ? ARGV[i + 1].to_i : default
end
# Defaults place the icons at pane y=28 exactly where vanilla's single row sat,
# with a 54px pitch: 49 of content plus 5 of breathing room.
win_y  = opt("y", 28)
win_h  = opt("height", 54)
pitch  = opt("pitch", 54)

abort "usage: ruby align_market_viewport.rb <in.xml> <out.xml> [--y N] [--height N] [--pitch N] [--apply]" unless src && dst && File.file?(src)
abort "height #{win_h} is less than pitch #{pitch} - a second row would peek in" if win_h < pitch
warn  "WARNING: pitch #{pitch} is under the 49px a row actually needs" if pitch < 49

doc = Nokogiri::XML(File.read(src, mode: "rb"))
def name_of(e) = (s = e.xpath("./s").first) ? s.text : ""

market = doc.xpath("//uientry").find { |e| name_of(e) == "world market" }
abort "no 'world market'" unless market
mk = market.xpath("./children").first

dw = mk.xpath("./uientry").find { |e| name_of(e) == "display_window" }
vs = mk.xpath("./uientry").find { |e| name_of(e) == "vslider" }
abort "world market has no display_window" unless dw
abort "world market has no vslider"        unless vs

# --- the state holds the BOUNDS; image_uses hold the PIXELS. Both, always. ---
def state_size(e)
  st = e.xpath("./states/state").first
  st && st.xpath("./i")
end

def set_height!(e, newh, label)
  si = state_size(e)
  abort "#{label}: no state" unless si && si.size >= 2
  oldh = si[1].text.to_i
  return [oldh, 0] if oldh == newh
  si[1].content = newh.to_s
  # Resize any image_use drawn at the old height, or the texture keeps its
  # original length and hangs out of the pane (the slider bar did exactly that).
  #
  # image_uses live INSIDE states/state, not as a direct child of the uientry -
  # `./image_uses` silently matches nothing and the bar stays the old length.
  # Scope to ./states so the vslider's own bar is found but its top/bottom/
  # handle CHILDREN (each with their own image_uses) are left alone.
  drawn = 0
  e.xpath("./states//image_uses//u").each do |u|
    next unless u.text.to_i == oldh
    n = u.next_sibling
    n = n.next_sibling while n && n.text? && n.text.strip.empty?
    next unless n && n.comment? && n.text.include?("y size")
    u.content = newh.to_s
    drawn += 1
  end
  [oldh, drawn]
end

def set_xy!(e, x, y)
  i = e.xpath("./i")
  i[0].content = x.to_s if x
  i[1].content = y.to_s if y
end

dwi = dw.xpath("./i")
dw_x = dwi[0].text.to_i
set_xy!(dw, nil, win_y)
oldh, drawn = set_height!(dw, win_h, "display_window")
puts "display_window : y -> #{win_y}, height #{oldh} -> #{win_h}#{drawn > 0 ? " (#{drawn} image_use)" : ""}"

set_xy!(vs, nil, win_y)
oldt, drawn = set_height!(vs, win_h, "vslider")
puts "vslider        : y -> #{win_y}, track #{oldt} -> #{win_h}#{drawn > 0 ? " (#{drawn} image_use)" : ""}"

# the `bottom` button tracks the slider's length
bot = vs.xpath("./children/uientry").find { |e| name_of(e) == "bottom" }
if bot
  bi = bot.xpath("./i")
  was = bi[1].text.to_i
  bi[1].content = (win_h - 1).to_s
  puts "  bottom button: y #{was} -> #{win_h - 1}"
else
  warn "WARNING: vslider has no `bottom` child - the end cap may float"
end

# --- re-space the rows ------------------------------------------------------
slots = dw.xpath("./children/uientry")
abort "display_window has no slots - run reparent_market_slots.rb first" if slots.empty?
rows = slots.map { |e| e.xpath("./i")[1].text.to_i }.uniq.sort
puts "\nrows #{rows.inspect} -> #{rows.each_index.map { |r| r * pitch }.inspect} (pitch #{pitch})"
slots.each do |e|
  i = e.xpath("./i")
  r = rows.index(i[1].text.to_i)
  i[1].content = (r * pitch).to_s
end

content = (rows.size - 1) * pitch + pitch
puts "content #{content}px in a #{win_h}px viewport -> scroll range #{content - win_h}"
puts "pane check: display_window spans y=#{win_y}..#{win_y + win_h} inside the 94px 'world market'" \
     "#{win_y + win_h > 94 ? '  *** OVERFLOWS THE PANE ***' : ''}"

if apply
  File.write(dst, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML), mode: "wb")
  puts "\nwritten: #{dst}"
else
  puts "\nDRY RUN (pass --apply to write)"
end
