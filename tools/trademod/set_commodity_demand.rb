# set_commodity_demand.rb - give a commodity per-region demand by mirroring an
# existing one's, in an esf2xml-converted startpos.
#
# Replaces the rum/sugar-specific version. Indices are resolved from the
# startpos's own commodities_order, so this works for any pair and stays correct
# as the order changes.
#
# WHY MIRROR RATHER THAN SET A FLAT NUMBER
#   The per-region demand figures already encode each region's wealth and
#   population, so copying a related commodity's column gives a believable
#   spread for free. A flat value makes every province want the new good
#   equally, which reads as obviously synthetic in play.
#
# WHICH ARRAY - the part worth getting right
#   A REGION record holds four u4_ary and only two are ever populated. Measured
#   on the vanilla Grand Campaign:
#
#     slot [0]    0 / 137 regions non-zero   (unused)
#     slot [1]    0 / 137 regions non-zero   (unused)
#     slot [2]   44 / 137 regions non-zero   PRODUCTION - only producing regions
#     slot [3]  124 / 137 regions non-zero   DEMAND     - nearly every region
#
#   Only the DEMAND slot is written. Mirroring into PRODUCTION would make every
#   region that produces the source commodity spontaneously produce the new one,
#   bypassing whatever building chain is supposed to be its only source. The
#   slot is detected by that same "populated in most regions" signature rather
#   than hardcoded, and the script refuses if the two candidates are ambiguous.
#
# Usage
#   ruby set_commodity_demand.rb <xml_dir> --commodity res_rum --mirror res_sugar
#                                [--scale 1.0] [--apply]

xml_dir = ARGV[0] && ARGV[0].tr("\\", "/")   # Dir.glob needs forward slashes
def opt(f, d = nil) i = ARGV.index(f); i ? ARGV[i + 1] : d end
target = opt("--commodity")
mirror = opt("--mirror")
scale  = opt("--scale", "1.0").to_f
apply  = ARGV.include?("--apply")

unless xml_dir && File.directory?(xml_dir) && target && mirror
  STDERR.puts "usage: ruby set_commodity_demand.rb <xml_dir> --commodity <key> --mirror <key> [--scale N] [--apply]"
  exit 1
end

# ---- resolve indices from the startpos's own order -------------------------
tm = File.join(xml_dir, "campaign_env", "trade_manager.xml")
abort "missing #{tm}" unless File.file?(tm)
order = File.read(tm, mode: "rb")[/<commodities_order>(.*?)<\/commodities_order>/m, 1].to_s.split
abort "could not read commodities_order" if order.empty?
ti = order.index(target)
mi = order.index(mirror)
abort "#{target.inspect} is not in commodities_order (#{order.join(' ')})" unless ti
abort "#{mirror.inspect} is not in commodities_order (#{order.join(' ')})" unless mi

puts "commodities_order: #{order.each_with_index.map { |c, i| "#{i}:#{c}" }.join('  ')}"
puts "target #{target} = index #{ti}, mirroring #{mirror} = index #{mi}, scale #{scale}"
puts

files = Dir.glob(File.join(xml_dir, "region", "*.xml"))
abort "no region files under #{xml_dir}/region" if files.empty?

# ---- detect the demand slot by how widely it is populated ------------------
width = order.size
nonzero = Hash.new(0)
shaped = 0
files.each do |f|
  a = File.read(f, mode: "rb").scan(/<u4_ary>([^<]*)<\/u4_ary>/).map { |m| m[0].split.map(&:to_i) }
  next unless a.size == 4 && a.all? { |x| x.size == width }
  shaped += 1
  a.each_with_index { |x, i| nonzero[i] += 1 if x.any? { |v| v != 0 } }
end
abort "no region has 4 arrays of width #{width} - run extend_commodity_arrays.rb first" if shaped.zero?

puts "slot population across #{shaped} regions:"
(0..3).each { |i| puts format("  [%d] %4d / %d", i, nonzero[i], shaped) }

ranked = (0..3).sort_by { |i| -nonzero[i] }
demand_slot, production_slot = ranked[0], ranked[1]
if nonzero[demand_slot].zero?
  abort "no populated slot found - cannot tell which is demand"
end
if nonzero[demand_slot] == nonzero[production_slot]
  abort "slots #{demand_slot} and #{production_slot} are equally populated - ambiguous, refusing to guess"
end
puts "-> demand = slot #{demand_slot}, production = slot #{production_slot} (left untouched)"
puts

changed = already = skipped = 0
examples = []
files.each do |f|
  src  = File.read(f, mode: "rb")
  arys = src.scan(/<u4_ary>([^<]*)<\/u4_ary>/).map { |m| m[0].split }
  unless arys.size == 4 && arys.all? { |a| a.size == width }
    skipped += 1
    next
  end
  d = arys[demand_slot]
  want = (d[mi].to_i * scale).round.to_s
  if d[ti] == want
    already += 1
    next
  end
  nd = d.dup
  nd[ti] = want
  seen = -1
  out = src.gsub(/<u4_ary>([^<]*)<\/u4_ary>/) do |whole|
    seen += 1
    seen == demand_slot ? "<u4_ary>#{nd.join(' ')}</u4_ary>" : whole
  end
  examples << [File.basename(f, ".xml"), d.join(" "), nd.join(" ")] if examples.size < 3
  changed += 1
  File.write(f, out, mode: "wb") if apply
end

puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
puts "regions changed      : #{changed}"
puts "already correct      : #{already}"
puts "skipped (wrong shape): #{skipped}"
puts
puts "examples (#{order.join(' ')}):"
examples.each { |n, b, a| puts "  #{n}\n    before: #{b}\n    after : #{a}" }

if skipped > 0
  STDERR.puts "\n#{skipped} region(s) were not 4 arrays of width #{width}."
  STDERR.puts "Run extend_commodity_arrays.rb first."
  exit 1
end
