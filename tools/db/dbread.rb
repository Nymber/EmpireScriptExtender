# dbread.rb - read a VERSIONED Empire DB table.
#
# WHY THIS EXISTS ALONGSIDE dbdump.ps1
#   dbdump handles the tables this mod writes, which are all version 0 with a
#   bare [u8][i32 rows] header. Several shipped tables are not: `units` is
#   version 2 and `unit_stats_land` is version 1, and both begin with the
#   VERSION MARKER fc fd fe ff followed by an int32 version. dbdump reads the
#   marker as the version byte, gets 252, finds no schema that fits and gives
#   up with "no schema version fits this file".
#
#   HEADER
#     [fd fe fc ff][i32 guid_char_len][UTF-16LE guid]   optional
#     [fc fd fe ff][i32 version]                        optional
#     [u8 unknown/flag][i32 row_count]
#
#   FIELD ENCODING
#     string / string_ascii   u16 length, then UTF-16LE / ASCII
#     optstring*              u8 present flag, then the string if present
#     int                     i32      float  f32      boolean  u8
#
# master_schema.xml often carries SEVERAL definitions for one table+version
# (unit_stats_land v1 has an 82-field and an 84-field form). Rather than guess,
# every candidate is decoded in full and the one that consumes the file EXACTLY
# wins - the same proof used for the .loc format. If none consumes it exactly,
# this reports that instead of returning plausible-looking garbage.
#
# Usage
#   ruby dbread.rb <file> <table_name> [--cols a,b,c] [--csv out.csv] [--limit N]

require "nokogiri"

require_relative "../../empire_paths"

file  = ARGV[0]
table = ARGV[1]
def opt(n, d = nil)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
want  = opt("cols")&.split(",")
csv   = opt("csv")
limit = (opt("limit") || "20").to_i
schema_path = opt("schema",
  File.join(EMPIRE.tools, "SaveParser/Data/master_schema.xml"))

abort "usage: ruby dbread.rb <file> <table_name> [--cols a,b,c] [--csv out] [--limit N]" unless file && table && File.file?(file)

d = File.binread(file)
pos = 0
guid = nil
if d[pos, 4] == "\xfd\xfe\xfc\xff".b
  pos += 4
  n = d[pos, 4].unpack1("l<"); pos += 4
  guid = d[pos, n * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += n * 2
end
version = 0
if d[pos, 4] == "\xfc\xfd\xfe\xff".b
  pos += 4
  version = d[pos, 4].unpack1("l<"); pos += 4
end
flag = d[pos].ord; pos += 1
rows = d[pos, 4].unpack1("l<"); pos += 4
header_end = pos
warn "#{File.basename(file)}: version #{version}, #{rows} rows#{guid ? ", guid #{guid}" : ''} (flag #{flag})"

doc = Nokogiri::XML(File.read(schema_path))
defs = doc.xpath("//table[@table_name='#{table}' and @table_version='#{version}']")
abort "no schema for #{table} version #{version}" if defs.empty?

def decode(d, pos, fields, rows)
  out = []
  rows.times do
    rec = {}
    fields.each do |f|
      case f[:type]
      when "string", "string_ascii", "optstring", "optstring_ascii"
        if f[:type].start_with?("opt")
          present = d[pos].ord; pos += 1
          if present.zero?
            rec[f[:name]] = ""
            next
          end
        end
        n = d[pos, 2].unpack1("v"); pos += 2
        if f[:type].include?("ascii")
          rec[f[:name]] = d[pos, n]; pos += n
        else
          rec[f[:name]] = d[pos, n * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += n * 2
        end
      when "int"     then rec[f[:name]] = d[pos, 4].unpack1("l<"); pos += 4
      when "float"   then rec[f[:name]] = d[pos, 4].unpack1("e");  pos += 4
      when "boolean" then rec[f[:name]] = (d[pos].ord != 0);        pos += 1
      else raise "unknown field type #{f[:type]}"
      end
    end
    out << rec
  end
  [out, pos]
end

winner = nil
defs.each_with_index do |t, i|
  fields = t.xpath("./field").map { |f| { name: f["name"], type: f["type"] } }
  begin
    recs, endpos = decode(d, header_end, fields, rows)
    if endpos == d.bytesize
      warn "  candidate #{i + 1} (#{fields.size} fields): EXACT - consumed all #{d.bytesize} bytes"
      winner = recs
      break
    else
      warn "  candidate #{i + 1} (#{fields.size} fields): consumed #{endpos} of #{d.bytesize}"
    end
  rescue => e
    warn "  candidate #{i + 1} (#{fields.size} fields): #{e.class} - #{e.message[0, 60]}"
  end
end
abort "no candidate consumed the file exactly - refusing to report guesses" unless winner

cols = want || winner.first.keys
if csv
  File.write(csv, ([cols.join(",")] + winner.map { |r| cols.map { |c| v = r[c].to_s; v.include?(",") ? "\"#{v}\"" : v }.join(",") }).join("\n"), mode: "wb")
  warn "wrote #{csv} (#{winner.size} rows)"
else
  puts cols.join(" | ")
  winner.first(limit).each { |r| puts cols.map { |c| r[c].to_s }.join(" | ") }
  puts "... #{winner.size - limit} more" if winner.size > limit
end
