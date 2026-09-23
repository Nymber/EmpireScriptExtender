# add_commodities.rb - append commodities to an esf2xml-converted startpos's
# CAMPAIGN_TRADE_MANAGER: the order lists and the manager's own per-commodity
# arrays.
#
# This is step 2a of docs/ADDING_A_COMMODITY.md, and the part that was hand
# edited until now. It handles N at once, because each esf2xml -> edit ->
# xml2esf cycle costs ~10 minutes on the 65MB startpos: twelve commodities must
# cost one cycle, not twelve.
#
# WHAT IT TOUCHES (campaign_env/trade_manager.xml only)
#   <commodities_order>   append each key
#   <resources_order>     append each key
#   u4_ary  "Commodities Baseline Price Per Unit"   append the price
#   u4_ary  "Commodities Current Price Per Unit"    append the price
#   flt_ary "Demand"                                append the demand weight
#   u4_ary  (unlabelled, commodity-width)           append 0
#   u4_ary  "Resources Trade Value"                 append 0
#
# APPENDING IS THE WHOLE POINT: position IS the runtime index, so adding on the
# end shifts nothing that already exists. Verify afterwards by reading the
# price array against the order - they must correspond entry for entry.
#
# Run extend_commodity_arrays.rb NEXT, to widen the per-region / per-faction /
# per-trade-route arrays to match. Leaving those behind is what produces a
# float bit pattern in an integer total (garbage trade income).
#
# INPUT  a manifest, one commodity per line:
#   <key>|<price>|<demand>
#   res_test01|10|0.05
#
# Usage
#   ruby add_commodities.rb <xml_dir> <manifest> [--apply]

xml_dir  = ARGV[0] && ARGV[0].tr("\\", "/")
manifest = ARGV[1]
apply    = ARGV.include?("--apply")
unless xml_dir && File.directory?(xml_dir) && manifest && File.file?(manifest)
  STDERR.puts "usage: ruby add_commodities.rb <xml_dir> <manifest> [--apply]"
  exit 1
end

entries = []
# Strip a UTF-8 BOM. PowerShell's Set-Content -Encoding UTF8 writes one, and
# Ruby does not remove it - so without this the FIRST key silently becomes
# "﻿res_test01" and goes into commodities_order corrupted.
File.read(manifest, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").split("\n").each do |line|
  s = line.strip
  next if s.empty? || s.start_with?("#")
  k, price, demand = s.split("|").map(&:strip)
  abort "bad manifest line: #{s}" unless k && price && demand
  entries << { key: k, price: price, demand: demand }
end
abort "manifest is empty" if entries.empty?

tm = File.join(xml_dir, "campaign_env", "trade_manager.xml")
abort "missing #{tm}" unless File.file?(tm)
src = File.read(tm, mode: "rb")

comm = src[/<commodities_order>(.*?)<\/commodities_order>/m, 1].to_s.split
res  = src[/<resources_order>(.*?)<\/resources_order>/m, 1].to_s.split
abort "could not read the order lists" if comm.empty? || res.empty?

dup = entries.map { |e| e[:key] } & comm
unless dup.empty?
  puts "already present, nothing to do: #{dup.join(' ')}"
  exit 0
end

# THE TWO LISTS ARE NOT THE SAME LIST. Every commodity must also be a resource
# (all 8 vanilla commodities appear in the 20-entry resources_order), but the
# converse is false - rice, sheep, cattle, fish and friends are resources that
# are not traded. So a new commodity whose key is ALREADY a resource - iron,
# timber and corn all are - must be appended to commodities_order ONLY.
#
# Appending it to resources_order as well produced a duplicate name in a list
# where POSITION IS IDENTITY. The engine keys its name->index map on the first
# occurrence, the loser index is never populated, stays 0, and the per-resource
# loop in Empire.exe at 0x009EB6B4 does `div [ecx+esi*4]` straight into it:
# STATUS_INTEGER_DIVIDE_BY_ZERO (0xC0000094), several minutes into a campaign.
# Nothing in the log; the VEH guard never sees an integer divide fault.
res_new = entries.reject { |e| res.include?(e[:key]) }
res_dup = entries.select { |e| res.include?(e[:key]) }

n_old_c, n_old_r = comm.size, res.size
n_new_c = n_old_c + entries.size
n_new_r = n_old_r + res_new.size

puts "commodities_order : #{n_old_c} -> #{n_new_c}"
puts "resources_order   : #{n_old_r} -> #{n_new_r}"
puts "appending         : #{entries.map { |e| e[:key] }.join(' ')}"
unless res_dup.empty?
  puts "already resources : #{res_dup.map { |e| e[:key] }.join(' ')}"
  puts "                    (commodity-only append - they keep their existing resource index)"
end
puts

out = src

# ---- the two order lists ---------------------------------------------------
# Match the file's own indentation so the result stays diff-readable.
indent = src[/<commodities_order>\s*\n(\s*)/m, 1] || " "
add_c = entries.map { |e| "#{indent}#{e[:key]}\n" }.join
add_r = res_new.map { |e| "#{indent}#{e[:key]}\n" }.join
out = out.sub(/(<commodities_order>.*?)(\s*<\/commodities_order>)/m) { "#{$1}\n#{add_c.chomp}#{$2}" }
unless res_new.empty?
  out = out.sub(/(<resources_order>.*?)(\s*<\/resources_order>)/m)   { "#{$1}\n#{add_r.chomp}#{$2}" }
end

# ---- the manager's own arrays ----------------------------------------------
# Identified by CURRENT WIDTH plus esfxml's own label, so an array that merely
# happens to be the same length is not caught by accident.
counts = Hash.new(0)
out = out.gsub(/<(u4_ary|flt_ary)>([^<]*)<\/\1>(<!--[^>]*-->)?/) do
  tag, body, label = $1, $2, $3.to_s
  vals = body.split
  if vals.size == n_old_c
    add = entries.map do |e|
      if label =~ /Price Per Unit/ then e[:price]
      elsif label =~ /Demand/      then e[:demand]
      else "0"
      end
    end
    counts[label.empty? ? "(unlabelled #{tag})" : label] += 1
    "<#{tag}>#{(vals + add).join(' ')}</#{tag}>#{label}"
  elsif vals.size == n_old_r
    # Resource-width arrays grow by the number of genuinely NEW resources, not
    # by the number of new commodities. Getting this wrong is what desynced the
    # arrays from resources_order in the first place.
    counts[label.empty? ? "(unlabelled #{tag}, resource width)" : label] += 1
    "<#{tag}>#{(vals + Array.new(res_new.size, '0')).join(' ')}</#{tag}>#{label}"
  else
    "<#{tag}>#{body}</#{tag}>#{label}"
  end
end

puts "arrays extended:"
counts.each { |k, v| puts format("  %-48s x%d", k, v) }
if counts.empty?
  STDERR.puts "\nNo arrays matched the old widths - refusing, something is off."
  exit 1
end

# ---- verify before writing --------------------------------------------------
chk_c = out[/<commodities_order>(.*?)<\/commodities_order>/m, 1].to_s.split
chk_r = out[/<resources_order>(.*?)<\/resources_order>/m, 1].to_s.split
ok = (chk_c.size == n_new_c && chk_r.size == n_new_r)

# Position is identity in both lists, so a repeated key is always a bug. This
# is checked on the RESULT rather than trusted from the logic above, because
# the logic above is exactly what was wrong before.
[["commodities_order", chk_c], ["resources_order", chk_r]].each do |name, list|
  d = list.tally.select { |_, n| n > 1 }.keys
  next if d.empty?
  STDERR.puts "DUPLICATE #{name} entries: #{d.join(' ')} - refusing to write."
  ok = false
end

# Every commodity must exist as a resource, or its per-resource slot never
# resolves. (Checked against vanilla: all 8 commodities are in resources_order.)
missing = chk_c - chk_r
unless missing.empty?
  STDERR.puts "commodities absent from resources_order: #{missing.join(' ')} - refusing to write."
  ok = false
end

price = out[/<u4_ary>([^<]*)<\/u4_ary><!-- Commodities Baseline Price Per Unit -->/, 1].to_s.split
ok &&= (price.size == n_new_c)

puts
puts "commodities_order now: #{chk_c.size} entries, ends #{chk_c.last(3).join(' ')}"
puts "resources_order   now: #{chk_r.size} entries, ends #{chk_r.last(3).join(' ')}"
puts "baseline prices   now: #{price.size} entries -> #{price.join(' ')}"
unless ok
  STDERR.puts "\nPost-edit check failed - not writing."
  exit 1
end

puts
puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
if apply
  File.write(tm, out, mode: "wb")
  puts "\nNEXT: ruby extend_commodity_arrays.rb #{xml_dir} --apply"
end
