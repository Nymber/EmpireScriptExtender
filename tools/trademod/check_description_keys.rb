# check_description_keys.rb - assert every building_description_texts row has
# BOTH a short and a long string in the .loc, under the exact key the engine
# builds.
#
# This is the check that was missing. A description key in the wrong shape is
# completely silent: the engine finds no string, draws nothing, and reports
# nothing - so 33 buildings shipped with no description at all and the only
# symptom was an empty panel.
#
#   key in building_description_texts_tables : small_coal_mine_european
#   loc keys the engine looks up             :
#     building_description_texts_short_description_small_coal_mine_european
#     building_description_texts_long_description_small_coal_mine_european
#
# Usage
#   ruby check_description_keys.rb <staged_dir>

dir = (ARGV[0] || File.join(ENV["TEMP"] || ENV["TMP"] || ".", "etw_chain_pack/staged")).tr("\\", "/")

def read_loc(path)
  d = File.binread(path)
  return {} unless d[0, 2] == "\xFF\xFE".b && d[2, 3] == "LOC".b
  n = d[10, 4].unpack1("l<")
  pos = 14
  out = {}
  n.times do
    kl = d[pos, 2].unpack1("v"); pos += 2
    k  = d[pos, kl * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += kl * 2
    vl = d[pos, 2].unpack1("v"); pos += 2
    v  = d[pos, vl * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += vl * 2
    pos += 1
    out[k] = v
  end
  out
end

loc = {}
Dir.glob("#{dir}/text/*.loc").each { |f| loc.merge!(read_loc(f)) }
abort "no .loc entries found under #{dir}/text" if loc.empty?

# The description table is a single string column; read the keys straight out
# of the binary rather than depending on a schema.
#
# DB table strings are UTF-16LE. Scanning for plain ASCII finds NOTHING and the
# check silently passes on an empty set - the same trap that once produced a
# confident, entirely invented claim that a row was missing from a pack.
#
# Read it properly instead of scavenging: [u8 version][i32 rows][rows], each
# row one UTF-16LE string with a u16 character-count prefix. A loose byte scan
# under-reported by four rows (adjacent strings run together), and a check that
# quietly skips rows is not a check.
keys = []
expected = 0
Dir.glob("#{dir}/db/building_description_texts_tables/*").each do |f|
  d = File.binread(f)
  pos = 0
  pos += 5 while d[pos, 4] == "\xfd\xfe\xfc\xff".b   # optional GUID/version marker
  ver  = d[pos].ord; pos += 1
  rows = d[pos, 4].unpack1("l<"); pos += 4
  expected += rows
  rows.times do
    break if pos + 2 > d.bytesize
    n = d[pos, 2].unpack1("v"); pos += 2
    keys << d[pos, n * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += n * 2
  end
end
abort "no description keys found - is #{dir}/db/building_description_texts_tables populated?" if keys.empty?
if keys.size != expected
  abort "read #{keys.size} key(s) but the table headers declare #{expected} row(s) - " \
        "the row format is not what this assumes, refusing to report a pass"
end
keys.uniq!

missing = []
keys.sort.each do |k|
  %w[short long].each do |kind|
    lk = "building_description_texts_#{kind}_description_#{k}"
    missing << lk unless loc.key?(lk)
  end
end

puts "#{keys.size} description key(s), #{loc.size} loc entrie(s)"
if missing.empty?
  puts "all short and long descriptions present"
  exit 0
end
puts "\nMISSING #{missing.size} string(s):"
missing.first(20).each { |m| puts "  #{m}" }
puts "  ... and #{missing.size - 20} more" if missing.size > 20

# Name the likely cause rather than just the symptom.
near = missing.map { |m| m.sub(/_european\z/, "european") }.select { |m| loc.key?(m) }
unless near.empty?
  puts "\n#{near.size} of them DO exist with the culture concatenated instead " \
       "(...mineeuropean). That is the building_culture_variants key shape, " \
       "which does not apply to this table - regenerate with " \
       "gen_building_descriptions.rb."
end
exit 1
