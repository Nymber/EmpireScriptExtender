# Diff a widened startpos tree against the pristine one it came from, array by
# array, and assert that every change is a legal widening:
#     8  -> 23   (commodity width)
#    20  -> 32   (resource width)
# Anything else is a bug. This is the check that would have caught the 35-wide
# resources_order before it cost a launch.
PRISTINE, EDITED = ARGV[0].tr("\\", "/"), ARGV[1].tr("\\", "/")

# Derive the legal widenings from the two trees' own order lists rather than
# hardcoding them, so this keeps working as the counts grow.
def orders(dir)
  tm = File.read(File.join(dir, "campaign_env", "trade_manager.xml"), mode: "rb")
  [tm[/<commodities_order>(.*?)<\/commodities_order>/m, 1].to_s.split,
   tm[/<resources_order>(.*?)<\/resources_order>/m, 1].to_s.split]
end
pc, pr = orders(PRISTINE)
ec, er = orders(EDITED)
LEGAL = { pc.size => ec.size, pr.size => er.size }
puts "legal widenings: #{pc.size}->#{ec.size} (commodities), #{pr.size}->#{er.size} (resources)"
abort "commodity and resource widths coincide - cannot tell them apart" if pc.size == pr.size

def arrays(path)
  return nil unless File.file?(path)
  File.read(path, mode: "rb")
      .scan(/<(u4_ary|i4_ary|flt_ary|u2_ary|bool_ary|byte_ary)>([^<]*)<\/\1>/)
      .map { |tag, body| [tag, body.split.size] }
end

widened = Hash.new(0)
bad     = []
skewed  = []
n = 0

Dir.glob("#{PRISTINE}/**/*.xml").each do |pf|
  rel = pf.sub("#{PRISTINE}/", "")
  ef  = File.join(EDITED, rel)
  pa, ea = arrays(pf), arrays(ef)
  next unless pa && ea
  n += 1
  if pa.size != ea.size
    skewed << rel if skewed.size < 5
    next
  end
  pa.each_with_index do |(ptag, pw), i|
    etag, ew = ea[i]
    next if pw == ew
    if LEGAL[pw] == ew
      widened["#{pw}->#{ew} #{etag}"] += 1
    else
      bad << "#{rel} [#{i}] <#{etag}> #{pw} -> #{ew}" if bad.size < 20
    end
  end
end

puts "compared #{n} files"
puts "\nlegal widenings:"
widened.sort_by { |_, c| -c }.each { |k, c| puts format("  %-22s x%d", k, c) }
puts "\nfiles whose array COUNT changed: #{skewed.size}#{skewed.empty? ? '' : ' -> ' + skewed.join(', ')}"
if bad.empty?
  puts "\nILLEGAL WIDTH CHANGES: none"
else
  puts "\nILLEGAL WIDTH CHANGES (#{bad.size} shown):"
  bad.each { |b| puts "  #{b}" }
end

# order-list sanity
c, r = ec, er
puts "\ncommodities_order #{c.size}  duplicates: #{c.tally.select { |_, v| v > 1 }.keys.inspect}"
puts "resources_order   #{r.size}  duplicates: #{r.tally.select { |_, v| v > 1 }.keys.inspect}"
puts "commodities missing from resources: #{(c - r).inspect}"
exit(bad.empty? && (c - r).empty? && c.tally.values.max == 1 && r.tally.values.max == 1 ? 0 : 1)
