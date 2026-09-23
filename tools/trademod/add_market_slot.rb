# add_market_slot.rb - add commodity slots to the World Market row of
# government_screens, and lay the whole set out as a GRID that fits the pane.
#
# WHY A SLOT IS NEEDED
#   government_screens.lua renders the row from whatever CampaignUI.TradeInfo()
#   returns:
#
#     for k, v in pairs(trade_info.prices) do
#       UIComponent(UIComponent(window:Find(k)):Find("dy_value")):SetStateText(v)
#     end
#
#   `k` is the SHORT key ("tobacco", not "res_tobacco"), so the layout needs a
#   child of exactly that name. This must ship TOGETHER with the matching line
#   in ese_commodities.txt: a price with no component makes Find return nil and
#   UIComponent(nil) raise, inside a loop that runs BEFORE the Supply and
#   Exports sections - so the whole Trade tab breaks, it does not merely hide
#   the commodity.
#
# WHY A GRID
#   The pane is 566 wide and the icons are 26. One row holds 8 comfortably
#   (70px pitch) and 9 at a squeeze (63px). The PRICE sits under each icon and
#   is ~20px wide, so prices collide well before icons do - the single row is
#   unusable past about 12. Beyond that the slots have to wrap.
#
#   Wrapping costs vertical space, and the World Market box does not sit alone:
#
#     world market  y=112  566 x 94
#     imports       y=211  566 x 190
#     exports       y=406  566 x 286   (ends 692)
#
#   so the box has to grow and its two siblings have to move down by the same
#   amount. This does that. Prefer FEW rows: two rows of ten costs +46px, three
#   rows costs +92 and starts to crowd the panel.
#
# HOW A SLOT IS IDENTIFIED
#   A commodity slot is a direct child of the "world market" container whose
#   subtree contains a "dy_value" component (the price text). That is what the
#   Lua actually requires, so it is the honest test - better than a hardcoded
#   list of names, and it keeps working as commodities are added.
#
#   IDs: the cloned block holds many <u>N</u><!-- ID ... --> fields, some of
#   which reference each other (a state's image_use repeats its image's ID).
#   Every ID is shifted by ONE constant per clone, keeping those links intact
#   while moving the clone clear of every existing ID. Only fields carrying the
#   "<!-- ID" comment are touched - plain <u> values are geometry.
#
# Usage
#   ruby add_market_slot.rb <government_screens.xml> [options]
#     --name    N[,N..]  UI component name(s) to add (must match ese_commodities.txt)
#     --clone   N        which existing slot to copy (default: the right-most)
#     --icon    N        reuse Skins\N.tga instead of Skins\<name>.tga
#     --tooltip T        tooltip text (single --name only)
#     --cols    N        slots per row (default: as many as fit legibly)
#     --rowheight N      vertical pitch between rows (default 46)
#     --apply
#
# Re-running only re-lays-out, so it is safe repeatedly.

require "set"

path = ARGV[0]
def opt(f, d = nil) i = ARGV.index(f); i ? ARGV[i + 1] : d end
names     = (opt("--name") || "").split(",").map(&:strip).reject(&:empty?)
clone     = opt("--clone")
icon      = opt("--icon")
tooltip   = opt("--tooltip")
cols_opt  = opt("--cols")
rowheight = opt("--rowheight", "46").to_i
apply     = ARGV.include?("--apply")
abort "usage: ruby add_market_slot.rb <government_screens.xml> [--name a,b,c] [--cols N] [--apply]" unless path && File.file?(path)

ID_SHIFT_BASE = 0x03000000
ICON_W        = 26
MIN_PITCH     = 44          # below this the price text under each icon collides

src = File.read(path, mode: "rb")

# ---------- helpers ---------------------------------------------------------
def container(lines)
  wi = lines.index { |l| l =~ /<s>world market<\/s><!-- title -->/ }
  raise "no 'world market' component" unless wi
  cs = nil
  (wi...lines.size).each { |i| (cs = i; break) if lines[i] =~ /<children count="\d+">/ }
  raise "world market has no <children>" unless cs
  [wi, cs]
end

def direct_children(lines, cs)
  kids = []
  i = cs + 1
  depth = 0
  start = nil
  while i < lines.size
    break if depth.zero? && lines[i] =~ /<\/children>/
    depth += lines[i].scan(/<uientry>/).size
    start = i if depth == 1 && start.nil? && lines[i] =~ /<uientry>/
    depth -= lines[i].scan(/<\/uientry>/).size
    if depth.zero? && start
      kids << [start, i]
      start = nil
    end
    i += 1
  end
  kids
end

def slots_of(lines, kids)
  kids.map { |a, b|
    body  = lines[a..b].join
    title = body[/<s>([^<]*)<\/s><!-- title -->/, 1]
    x     = body[/<i>(-?\d+)<\/i><!-- x offset -->/, 1]
    y     = body[/<i>(-?\d+)<\/i><!-- y offset -->/, 1]
    next nil unless title && x && y && body.include?("<s>dy_value</s>")
    { title: title, x: x.to_i, y: y.to_i, a: a, b: b }
  }.compact.sort_by { |s| [s[:y], s[:x]] }
end

lines   = src.lines
wi, cs  = container(lines)
slots   = slots_of(lines, direct_children(lines, cs))
abort "found no commodity slots (children with a dy_value)" if slots.empty?

# pane size lives on the container's first state
pane_w = pane_h = nil
(wi...[wi + 800, lines.size].min).each do |j|
  if lines[j] =~ /<s>[^<]*<\/s><!-- title - NewState/ || lines[j] =~ /<s>NewState<\/s>/
    pane_w = lines[j + 1][/<i>(-?\d+)<\/i>/, 1].to_i
    pane_h = lines[j + 2][/<i>(-?\d+)<\/i>/, 1].to_i
    break
  end
end
abort "could not read the pane size" unless pane_w && pane_w > 0

base_y = slots.map { |s| s[:y] }.min
puts "world market  : #{pane_w} x #{pane_h}, #{slots.size} slot(s), first row y=#{base_y}"
puts "existing      : #{slots.map { |s| s[:title] }.join(' ')}"

# ---------- clone any new slots --------------------------------------------
out = src
added = 0
names.each_with_index do |name, ni|
  if slots.any? { |s| s[:title] == name }
    puts "  '#{name}' already present"
    next
  end
  lines2 = out.lines
  _, cs2 = container(lines2)
  cur = slots_of(lines2, direct_children(lines2, cs2))
  tmpl = clone ? cur.find { |s| s[:title] == clone } : cur.max_by { |s| [s[:y], s[:x]] }
  abort "no slot named #{clone.inspect} to clone" unless tmpl

  block = lines2[tmpl[:a]..tmpl[:b]].join
  all_ids   = out.scan(/<u>(\d+)<\/u>/).flatten.map(&:to_i).to_set
  block_ids = block.scan(/<u>(\d+)<\/u><!-- ID/).flatten.map(&:to_i)
  shift = ID_SHIFT_BASE + ni * 0x00100000
  bad = block_ids.map { |v| v + shift }.select { |v| all_ids.include?(v) }
  abort "id shift for #{name} collides with #{bad.size} existing id(s)" unless bad.empty?
  abort "id shift overflows 32 bits" if block_ids.any? { |v| v + shift > 0xFFFFFFFF }

  t  = tmpl[:title]
  cl = block.dup
  cl = cl.gsub(/<u>(\d+)<\/u>(<!-- ID[^>]*-->)/) { "<u>#{$1.to_i + shift}</u><!-- ID -->" }
  cl = cl.sub(/<s>#{Regexp.escape(t)}<\/s><!-- title -->/, "<s>#{name}</s><!-- title -->")
  cl = cl.gsub("Skins\\#{t}.tga", "Skins\\#{icon || name}.tga")
  cl = cl.gsub("<unicode>#{t.capitalize}</unicode>", "<unicode>#{tooltip || name.capitalize}</unicode>")
  cl = cl.gsub(/#{Regexp.escape(t)}_NewState_Tooltip_/, "#{name}_NewState_Tooltip_")
  left = cl.scan(/#{Regexp.escape(t)}/i)
  abort "clone for #{name} still mentions #{t} #{left.size}x" unless left.empty?

  out = lines2[0..tmpl[:b]].join + cl + lines2[(tmpl[:b] + 1)..-1].join
  n = lines2[cs2][/<children count="(\d+)">/, 1].to_i
  # Replace BY INDEX. Substituting the line TEXT patches the first identical
  # line in the file, and `<children count="N">` at this indentation is not
  # unique - that silently bumped the wrong container elsewhere. The clone is
  # spliced after cs2, so the index is still valid.
  outl = out.lines
  abort "line #{cs2 + 1} is no longer the children count" unless outl[cs2] =~ /<children count="#{n}">/
  outl[cs2] = outl[cs2].sub(/<children count="\d+">/, "<children count=\"#{n + 1}\">")
  out = outl.join
  added += 1
  puts "  + #{name} (cloned #{t}, icon #{icon || name}.tga)"
end

# ---------- lay the whole set out as a grid --------------------------------
lines3 = out.lines
_, cs3 = container(lines3)
slots  = slots_of(lines3, direct_children(lines3, cs3))
count  = slots.size

cols = cols_opt ? cols_opt.to_i : [count, [(pane_w - ICON_W) / MIN_PITCH, 1].max].min
cols = 1 if cols < 1
rows = (count.to_f / cols).ceil
pitch = cols > 1 ? (pane_w - ICON_W) / cols : 0
span  = (cols - 1) * pitch + ICON_W
startx = (pane_w - span) / 2

# --no-grow: leave the pane and its siblings alone and let the SCROLLBAR reveal
# the extra rows. That is the whole point of the scrollbar - growing the pane
# costs vertical space the panel does not have (+46 pushes Exports off the
# bottom), whereas scrolling costs none.
grow = ARGV.include?("--no-grow") ? 0 : (rows - 1) * rowheight
puts
puts "grid          : #{count} slots -> #{cols} cols x #{rows} row(s), pitch #{pitch}"
puts "pane height   : #{pane_h} -> #{pane_h + grow}#{grow.zero? ? ' (unchanged)' : ''}"
if pitch > 0 && pitch < MIN_PITCH
  STDERR.puts "\nREFUSING: pitch #{pitch} is below #{MIN_PITCH}px - the price text under each"
  STDERR.puts "icon would overlap. Pass a smaller --cols so the slots wrap onto more rows."
  exit 1
end

slots.each_with_index do |s, i|
  nx = startx + (i % cols) * pitch
  ny = base_y + (i / cols) * rowheight
  out = out.sub(/(<s>#{Regexp.escape(s[:title])}<\/s><!-- title -->\s*\n\s*<i>)-?\d+(<\/i><!-- x offset -->\s*\n\s*<i>)-?\d+(<\/i><!-- y offset -->)/) { "#{$1}#{nx}#{$2}#{ny}#{$3}" }
end

# ---------- grow the pane and push the siblings down ------------------------
if grow > 0
  # the container's own state height
  l4 = out.lines
  wi4, = container(l4)
  state_j = nil
  old_h = nil
  (wi4...[wi4 + 800, l4.size].min).each do |j|
    if l4[j] =~ /<s>[^<]*<\/s><!-- title - NewState/ || l4[j] =~ /<s>NewState<\/s>/
      state_j = j
      old_h = l4[j + 2][/<i>(-?\d+)<\/i>/, 1].to_i
      l4[j + 2] = l4[j + 2].sub(/<i>-?\d+<\/i>/, "<i>#{old_h + grow}</i>")
      break
    end
  end
  abort "could not find the container's state to grow" unless state_j
  new_h = old_h + grow

  # THE FRAME MUST GROW TOO. The pane is drawn as a 9-slice of 16px pieces, and
  # the state's image_uses place them with values derived from the OLD height:
  #
  #   bottom edge / BL / BR   y offset = H - 16
  #   left / right / fill     y size   = H - 32
  #
  # Changing only the state height moves the layout bounds but leaves the
  # border graphics where they were, so the extra rows render OUTSIDE the box.
  # Rewrite the six derived values; the four that are 0 or 16 are corners and
  # top edges and must not move.
  us = ue = nil
  (state_j...l4.size).each do |j|
    us = j if us.nil? && l4[j] =~ /<image_uses count="\d+">/
    if us && l4[j] =~ /<\/image_uses>/
      ue = j
      break
    end
  end
  if us && ue
    fixed = 0
    (us..ue).each do |j|
      if l4[j] =~ /<u>#{old_h - 16}<\/u><!-- y offset -->/
        l4[j] = l4[j].sub(/<u>\d+<\/u>/, "<u>#{new_h - 16}</u>"); fixed += 1
      elsif l4[j] =~ /<u>#{old_h - 32}<\/u><!-- y size -->/
        l4[j] = l4[j].sub(/<u>\d+<\/u>/, "<u>#{new_h - 32}</u>"); fixed += 1
      end
    end
    puts "frame 9-slice : #{fixed} piece(s) re-placed for height #{new_h} " \
         "(y offset #{old_h - 16}->#{new_h - 16}, y size #{old_h - 32}->#{new_h - 32})"
    if fixed < 6
      STDERR.puts "WARNING: expected 6 frame pieces to move, moved #{fixed} - check the border renders correctly"
    end
  else
    STDERR.puts "WARNING: could not find the container's image_uses; the frame will not grow"
  end
  out = l4.join

  # Siblings stacked BELOW the world market must move down by the same amount,
  # or the grown box overlaps them.
  ["imports", "exports"].each do |sib|
    out = out.sub(/(<s>#{sib}<\/s><!-- title -->\s*\n\s*<i>-?\d+<\/i><!-- x offset -->\s*\n\s*<i>)(-?\d+)(<\/i><!-- y offset -->)/) do
      "#{$1}#{$2.to_i + grow}#{$3}"
    end
    ny = out[/<s>#{sib}<\/s><!-- title -->\s*\n\s*<i>-?\d+<\/i><!-- x offset -->\s*\n\s*<i>(-?\d+)<\/i><!-- y offset -->/, 1]
    puts "#{sib} moved down #{grow} -> y=#{ny}"
  end
end

if added > 0
  puts
  puts "REMINDER - this tool does NOT do these:"
  names.each do |n|
    puts "  .loc  #{n}_NewState_Tooltip_6d003a = #{(tooltip || n.capitalize).inspect}"
  end
  puts "  icon  data\\UI\\Campaign UI\\Skins\\#{icon || '<name>'}.tga must exist in a pack"
  puts "  ESE   a matching line in ese_commodities.txt"
end

puts
puts "size: #{src.bytesize} -> #{out.bytesize} bytes"
if apply
  File.write(path, out, mode: "wb")
  puts "written. Convert back with:  ruby bin/xml2ui <xml> <uifile>"
else
  puts "(dry run - pass --apply to write)"
end
