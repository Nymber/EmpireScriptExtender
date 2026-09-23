# loctool.rb - read, search and extend Empire .loc localisation files.
#
# FORMAT (validated against the shipped 32,700-entry localisation.loc, read to
# EOF with zero bytes left over - which is the only real proof a binary format
# has been decoded correctly):
#
#   FF FE                BOM
#   "LOC"                ASCII marker
#   00                   one null
#   int32                version (1)
#   int32                entry count
#   per entry:
#     uint16 keyLen      followed by keyLen UTF-16LE chars
#     uint16 valLen      followed by valLen UTF-16LE chars
#     uint8  flag
#
#   The trailing flag byte is why a naive "split on nulls" decode produces
#   interleaved garbage - it leaves every following entry off by one byte.
#
# Usage
#   ruby loctool.rb list   <file.loc> [substring]
#   ruby loctool.rb add    <file.loc> <key> <value> [--apply]
#   ruby loctool.rb addfile <file.loc> <entries.txt> [--apply]
#   ruby loctool.rb rmkeys <file.loc> <substring> [--apply]
#   ruby loctool.rb verify <file.loc>
#
# In an `addfile` entries file a literal backslash-n in the VALUE becomes a real
# newline, because the file is line-based and Empire's long descriptions are
# multi-paragraph (vanilla's all begin with two newlines).
#
# FLAG BYTE: localisation.loc uses flag 0 and ui.loc uses flag 1. Both are
# "real" - the flag is not a valid/invalid marker, so do not go hunting for a
# missing string on those grounds.

def read_loc(path)
  d = File.binread(path)
  raise "not a .loc (bad BOM)"    unless d[0, 2] == "\xFF\xFE".b
  raise "not a .loc (no LOC tag)" unless d[2, 3] == "LOC".b
  pos = 5 + 1                      # "LOC" + the single null
  version = d[6, 4].unpack1("l<")
  count   = d[10, 4].unpack1("l<")
  pos = 14
  entries = []
  count.times do
    klen = d[pos, 2].unpack1("v"); pos += 2
    key  = d[pos, klen * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += klen * 2
    vlen = d[pos, 2].unpack1("v"); pos += 2
    val  = d[pos, vlen * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += vlen * 2
    flag = d[pos].unpack1("C"); pos += 1
    entries << [key, val, flag]
  end
  [version, entries, pos, d.bytesize]
end

def write_loc(path, version, entries)
  out = "\xFF\xFE".b + "LOC".b + "\x00".b
  out << [version].pack("l<") << [entries.size].pack("l<")
  entries.each do |key, val, flag|
    k = key.encode("UTF-16LE").b
    v = val.encode("UTF-16LE").b
    out << [k.bytesize / 2].pack("v") << k
    out << [v.bytesize / 2].pack("v") << v
    out << [flag].pack("C")
  end
  File.binwrite(path, out)
  out.bytesize
end

cmd, path = ARGV[0], ARGV[1]
abort "usage: ruby loctool.rb list|add|verify <file.loc> ..." unless cmd && path && File.file?(path)

version, entries, consumed, total = read_loc(path)

case cmd
when "verify", "list"
  ok = (consumed == total)
  puts "#{File.basename(path)}: version #{version}, #{entries.size} entries"
  puts "consumed #{consumed} of #{total} bytes -> #{ok ? 'EXACT (format correct)' : "MISMATCH, #{total - consumed} left over"}"
  if cmd == "list"
    term = ARGV[2]
    sel = term ? entries.select { |k, _| k.include?(term) } : entries
    puts "\n#{sel.size} matching entr#{sel.size == 1 ? 'y' : 'ies'}:"
    sel.first(40).each { |k, v, f| puts "  #{k}\n      = #{v.inspect} (flag #{f})" }
    puts "  ... and #{sel.size - 40} more" if sel.size > 40
  end
  exit(ok ? 0 : 1)

when "addfile"
  # Batch form: a pipe-separated key|value file. Adding ~90 entries one call at
  # a time is both slow and a chance to get one wrong silently.
  src = ARGV[2]
  apply = ARGV.include?("--apply")
  abort "usage: ruby loctool.rb addfile <file.loc> <entries.txt> [--apply]" unless src && File.file?(src)
  added = updated = same = 0
  File.read(src, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").split("\n").each do |line|
    s = line.strip
    next if s.empty? || s.start_with?("#")
    k, v = s.split("|", 2)
    next unless k && v
    v = v.gsub('\n', "\n")      # the file is line-based; long descriptions are not
    if (i = entries.index { |ek, _| ek == k })
      if entries[i][1] == v then same += 1
      else entries[i] = [k, v, entries[i][2]]; updated += 1 end
    else
      entries << [k, v, 1]      # real entries carry flag 1
      added += 1
    end
  end
  puts "#{File.basename(path)}: +#{added} added, #{updated} updated, #{same} already correct"
  if apply
    n = write_loc(path, version, entries)
    v2, e2, c2, t2 = read_loc(path)
    abort "re-read failed - the file is corrupt" unless c2 == t2
    puts "written: #{n} bytes, #{e2.size} entries, round-trip verified"
  else
    puts "(dry run - pass --apply to write)"
  end

when "rmkeys"
  # Delete every entry whose key CONTAINS the substring. Used to retire keys
  # written in a wrong shape, which are invisible in game - the engine simply
  # finds nothing and shows nothing, so they cannot be spotted by looking.
  term = ARGV[2]
  apply = ARGV.include?("--apply")
  # --regex matters when good and bad keys share a prefix: the chain buildings'
  # broken description keys sit right beside the rum distillery's CORRECT ones,
  # so a substring match would have deleted the working entries too.
  rx = ARGV.include?("--regex")
  abort "usage: ruby loctool.rb rmkeys <file.loc> <substring|regex> [--regex] [--apply]" unless term
  pat = rx ? Regexp.new(term) : nil
  doomed = entries.select { |k, _| rx ? k =~ pat : k.include?(term) }
  puts "#{doomed.size} of #{entries.size} entries match #{term.inspect}#{rx ? ' (regex)' : ''}"
  doomed.first(6).each { |k, v| puts "  #{k}\n      = #{v[0, 70].inspect}" }
  puts "  ... and #{doomed.size - 6} more" if doomed.size > 6
  if doomed.empty?
    puts "nothing to do"
    exit 0
  end
  kept = entries.reject { |k, _| rx ? k =~ pat : k.include?(term) }
  if apply
    n = write_loc(path, version, kept)
    _, e2, c2, t2 = read_loc(path)
    abort "re-read failed - the file is corrupt" unless c2 == t2
    puts "written: #{n} bytes, #{e2.size} entries remain, round-trip verified"
  else
    puts "(dry run - pass --apply to write)"
  end

when "add"
  key, val = ARGV[2], ARGV[3]
  apply = ARGV.include?("--apply")
  abort "usage: ruby loctool.rb add <file.loc> <key> <value> [--apply]" unless key && val
  if (i = entries.index { |k, _| k == key })
    puts "key already present: #{key} = #{entries[i][1].inspect}"
    if entries[i][1] == val
      puts "value already correct - nothing to do"
      exit 0
    end
    entries[i] = [key, val, entries[i][2]]
    puts "updating value -> #{val.inspect}"
  else
    # Real entries carry flag 1 (checked against tobacco_NewState_Tooltip_6d003a
    # and friends in the shipped ui.loc), so match that rather than guessing 0.
    entries << [key, val, 1]
    puts "adding #{key} = #{val.inspect} (flag 1)"
  end
  if apply
    n = write_loc(path, version, entries)
    v2, e2, c2, t2 = read_loc(path)
    abort "re-read failed" unless c2 == t2
    puts "written: #{n} bytes, #{e2.size} entries, round-trip verified"
  else
    puts "(dry run - pass --apply to write)"
  end
else
  abort "unknown command #{cmd}"
end
