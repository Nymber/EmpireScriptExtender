# reparent_market_slots.rb - move the World Market commodity slots INSIDE the
# display_window so the engine clips them, which is what makes scrolling real.
#
# WHY THIS IS NEEDED
#   A `display_window` in Empire is not a decorative box: it is the scroll
#   viewport, and it clips its CHILDREN. The vanilla imports/exports lists look
#   like they contradict that - their display_window has `children count="0"` in
#   the layout - but that is because those rows are built at RUNTIME:
#
#     display_window:DestroyChildren()
#     local parent = display_window:Address()
#     Component.CreateComponentFromTemplate("TradeRouteEntry", "entry"..f, parent, 0, ...)
#
#   The World Market slots, by contrast, are STATIC layout components, and
#   add_market_slot.rb cloned them as siblings of the display_window rather than
#   children of it. Siblings are not clipped, so with 23 commodities on 3 rows
#   the second and third rows simply drew over the panel and across the Supply
#   heading below it. Nothing was wrong with the scrollbar; there was nothing
#   for it to scroll.
#
# WHAT IT DOES
#   Every child of "world market" that is not the header, the display_window or
#   the vslider is moved into the display_window's <children>, with its x/y
#   rebased from world-market-relative to display_window-relative.
#
# THE COUNT TRAP
#   etwng's xml2ui writes `<children count="N">` VERBATIM (see
#   lib/xml2ui.rb:124 - `@ui.put_u attributes[:count].to_i`, with a TODO
#   admitting it is hand-checked). A count that disagrees with the number of
#   nodes produces a corrupt .ui that fails at load, so every children-array
#   count in the document is recomputed from the actual node count here.
#
# Usage
#   ruby reparent_market_slots.rb <in.xml> <out.xml> [--apply]

require "nokogiri"

src, dst = ARGV[0], ARGV[1]
apply    = ARGV.include?("--apply")
abort "usage: ruby reparent_market_slots.rb <in.xml> <out.xml> [--apply]" unless src && dst && File.file?(src)

KEEP = %w[header display_window vslider]

doc = Nokogiri::XML(File.read(src, mode: "rb"))

def name_of(e)
  s = e.xpath("./s").first
  s ? s.text : ""
end

def xy(e)
  i = e.xpath("./i")
  [i[0].text.to_i, i[1].text.to_i]
end

market = doc.xpath("//uientry").find { |e| name_of(e) == "world market" }
abort "no 'world market' component" unless market

mkids = market.xpath("./children").first
abort "'world market' has no <children>" unless mkids

dw = mkids.xpath("./uientry").find { |e| name_of(e) == "display_window" }
abort "'world market' has no display_window child" unless dw
dwx, dwy = xy(dw)
puts "display_window at (#{dwx},#{dwy})"

dwkids = dw.xpath("./children").first
unless dwkids
  dwkids = Nokogiri::XML::Node.new("children", doc)
  dwkids["count"] = "0"
  # <children> sits immediately before the trailing <s></s><!-- template -->
  tmpl = dw.xpath("./s").last
  tmpl ? tmpl.add_previous_sibling(dwkids) : dw.add_child(dwkids)
  puts "created a <children> array on display_window"
end

moved = []
mkids.xpath("./uientry").each do |e|
  n = name_of(e)
  next if KEEP.include?(n)
  x, y = xy(e)
  i = e.xpath("./i")
  i[0].content = (x - dwx).to_s
  i[1].content = (y - dwy).to_s
  e.unlink
  dwkids.add_child(e)
  moved << [n, x, y, x - dwx, y - dwy]
end

abort "nothing to move - already reparented?" if moved.empty?

puts "moved #{moved.size} slot(s) into display_window:"
moved.each { |n, ox, oy, nx, ny| puts format("  %-20s (%3d,%3d) -> (%3d,%3d)", n, ox, oy, nx, ny) }

# Recompute EVERY children count from reality - see THE COUNT TRAP above.
fixed = 0
doc.xpath("//children").each do |c|
  real = c.xpath("./uientry").size.to_s
  next if c["count"] == real
  fixed += 1
  c["count"] = real
end
puts "\nchildren counts corrected: #{fixed}"
puts "  world market   -> #{mkids['count']} (header, display_window, vslider)"
puts "  display_window -> #{dwkids['count']}"

rows = moved.map { |m| m[4] }.uniq.sort
puts "  rows at y = #{rows.join(', ')} (pitch #{rows.size > 1 ? rows[1] - rows[0] : 'n/a'})"

if apply
  File.write(dst, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML), mode: "wb")
  puts "\nwritten: #{dst}"
else
  puts "\nDRY RUN (pass --apply to write)"
end
