# extend_commodity_arrays.rb - widen every per-commodity / per-resource array in
# an esf2xml-converted startpos by one slot.
#
# WHY THIS EXISTS
#   Adding a commodity means editing CAMPAIGN_TRADE_MANAGER's own arrays, but
#   the SAME commodity index is used by arrays living on other records. Leave
#   those at the old width and anything iterating by the manager's count reads
#   one element past the end - which surfaces as a float bit pattern in an
#   integer total (garbage trade income), and downstream as a UI crash when a
#   panel sizes a buffer from the garbage.
#
#   Records that carry them:
#     region                      4 x u4_ary(commodities) + 1 x bool_ary(resources)
#     factions                                              1 x bool_ary(resources)
#     international_trade_routes  1 x u4_ary(commodities) + 1 x u4_ary(resources)
#     domestic_trade_routes       1 x u4_ary(commodities)
#
# WHY APPENDING IS CORRECT
#   A new commodity goes on the END of commodities_order (and resources_order),
#   so it takes the next index and nothing existing shifts. Verify that before
#   running this: the trade manager's own price array must read entry-for-entry
#   against commodities_order. The appended value is 0, which is ordinary data -
#   vanilla region demand arrays already contain plenty of zeroes.
#
# SAFETY
#   Widths are DETECTED, not assumed, so this keeps working as the count grows
#   (8->9, 9->10, ...). Only the four directories above are touched, and only
#   arrays whose length equals the detected width. 8- and 20-element arrays are
#   common elsewhere (bdi_pool, campaign-pathfinder, cai_*) holding unrelated
#   data such as "BDI Information" and "Boundary IDs" - those must not move.
#   Every directory's tally is checked against what the survey predicted, and
#   the script exits non-zero on any mismatch rather than half-applying.
#
# Usage
#   ruby extend_commodity_arrays.rb <xml_dir> [--apply]

require "set"

xml_dir = ARGV[0] && ARGV[0].tr("\\", "/")   # Dir.glob needs forward slashes
apply   = ARGV.include?("--apply")
unless xml_dir && File.directory?(xml_dir)
  STDERR.puts "usage: ruby extend_commodity_arrays.rb <xml_dir> [--apply]"
  exit 1
end

def arrays(text, tag)
  text.scan(/<#{tag}>([^<]*)<\/#{tag}>/).map { |m| m[0].split }
end

# ---- 1. detect the current widths from the trade manager -------------------
tm = File.join(xml_dir, "campaign_env", "trade_manager.xml")
abort "missing #{tm}" unless File.file?(tm)
tmx = File.read(tm, mode: "rb")
n_comm = tmx[/<commodities_order>(.*?)<\/commodities_order>/m, 1].to_s.split.size
n_res  = tmx[/<resources_order>(.*?)<\/resources_order>/m, 1].to_s.split.size
abort "could not read commodities_order / resources_order" if n_comm.zero? || n_res.zero?

# Detect what the per-record arrays are CURRENTLY at, rather than assuming they
# are exactly one short. That makes this work for any gap - adding twelve
# commodities in one pass is the same operation as adding one.
def common_width(files, tag, want_arrays)
  tally = Hash.new(0)
  files.each do |f|
    a = File.read(f, mode: "rb").scan(/<#{tag}>([^<]*)<\/#{tag}>/).map { |m| m[0].split.size }
    next if want_arrays && a.size != want_arrays
    a.each { |w| tally[w] += 1 }
  end
  tally.max_by { |_, c| c }&.first
end

region_files = Dir.glob(File.join(xml_dir, "region", "*.xml"))
abort "no region files under #{xml_dir}/region" if region_files.empty?
old_comm = common_width(region_files, "u4_ary", 4)
old_res  = common_width(region_files, "bool_ary", nil)
abort "could not detect current per-record widths" unless old_comm && old_res

puts "trade manager      : #{n_comm} commodities, #{n_res} resources"
puts "per-record arrays  : #{old_comm} commodities, #{old_res} resources"
if old_comm == n_comm && old_res == n_res
  puts "\nalready in step - nothing to widen."
  exit 0
end
abort "per-record arrays (#{old_comm}) are WIDER than the order (#{n_comm}) - refusing" if old_comm > n_comm
abort "per-record arrays (#{old_res}) are WIDER than the order (#{n_res}) - refusing"  if old_res  > n_res
# If the two widths ever coincide, a commodity array and a resource array under
# the same tag become indistinguishable and this cannot safely proceed.
abort "commodity and resource widths are both #{old_comm} - ambiguous, refusing" if old_comm == old_res
puts "widening by #{n_comm - old_comm} (commodities) and #{n_res - old_res} (resources)"
puts

# ---- 2. survey, so the apply step has something to check itself against ----
RULES = {
  "region"                     => [["u4_ary", :comm], ["bool_ary", :res]],
  "factions"                   => [["bool_ary", :res]],
  "international_trade_routes" => [["u4_ary", :comm], ["u4_ary", :res]],
  "domestic_trade_routes"      => [["u4_ary", :comm]],
}
WIDTH  = { comm: old_comm, res: old_res }   # what to look for
TARGET = { comm: n_comm,   res: n_res }     # what to grow it to

expected = Hash.new(0)
RULES.each do |dir, rules|
  path = File.join(xml_dir, dir)
  abort "MISSING directory: #{path}" unless File.directory?(path)
  Dir.glob(File.join(path, "**", "*.xml")).each do |f|
    text = File.read(f, mode: "rb")
    rules.each { |tag, kind| expected[[dir, tag, kind]] += arrays(text, tag).count { |a| a.size == WIDTH[kind] } }
  end
end

# ---- 3. apply ---------------------------------------------------------------
changed = Hash.new(0)
files_touched = 0
RULES.each do |dir, rules|
  Dir.glob(File.join(xml_dir, dir, "**", "*.xml")).each do |f|
    src = File.read(f, mode: "rb")
    out = src.dup
    # ONE pass per tag, deciding each array's kind from the width it had going
    # in. Applying the rules in sequence is wrong: international_trade_routes
    # holds a commodities array AND a resources array under the same tag, so
    # widening commodities 9->21 made those arrays match the resources rule
    # (width 21) and they were widened a second time.
    rules.group_by { |tag, _| tag }.each do |tag, group|
      kinds = group.map { |_, k| k }
      out = out.gsub(/<#{tag}>([^<]*)<\/#{tag}>/) do |whole|
        vals = $1.split
        kind = kinds.find { |k| vals.size == WIDTH[k] }
        if kind
          changed[[dir, tag, kind]] += 1
          "<#{tag}>#{(vals + Array.new(TARGET[kind] - vals.size, "0")).join(" ")}</#{tag}>"
        else
          whole
        end
      end
    end
    next if out == src
    files_touched += 1
    File.write(f, out, mode: "wb") if apply
  end
end

puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
puts
puts format("%-28s %-9s %-6s %8s %8s", "dir", "tag", "width", "found", "expected")
ok = true
RULES.each do |dir, rules|
  rules.each do |tag, kind|
    got, exp = changed[[dir, tag, kind]], expected[[dir, tag, kind]]
    good = (got == exp && exp > 0)
    ok &&= good
    puts format("%-28s %-9s %-6d %8d %8d  %s", dir, tag, WIDTH[kind], got, exp,
                good ? "ok" : (exp.zero? ? "*** NOTHING FOUND ***" : "*** MISMATCH ***"))
  end
end
puts
puts "files touched: #{files_touched}"
unless ok
  STDERR.puts "\nCounts do not match the survey - refusing to treat this as a good run."
  STDERR.puts "If the arrays are already widened this is expected; check with a fresh convert."
  exit 1
end
puts "all counts as expected."
