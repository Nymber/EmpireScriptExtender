# build_pack_stream.rb - build a PFH0 pack by STREAMING, for trees too large to
# assemble in memory.
#
# WHY NOT new_commodity_pack/build_pack.ps1
#   That script reads every file into a byte array, accumulates them in a list,
#   and writes through a MemoryStream. For the commodity and mesh packs that is
#   fine. The rigid-model pack is 1.37 GB, which would need roughly 2.7 GB live
#   at once. This walks the tree twice instead - once to build the index, once
#   to copy bytes - and never holds more than one file.
#
# It is otherwise byte-for-byte the same format and the same rules:
#   * mod_type 4 ("movie") because type 3 sat inert through three test launches
#   * internal paths LOWERCASED - a file only overrides a base-game one when the
#     path matches, and vanilla is entirely lowercase
#   * backup patterns refused outright; anything left in the staged tree ships,
#     and a stray .bak has twice been packed as though it were game data
#
# Usage
#   ruby build_pack_stream.rb <staged_dir> <out.pack>

SKIP = [/\.bak$/i, /\.orig$/i, /\.broken/i, /\.prev/i, /\.tmp$/i, /~$/]

staged, out = ARGV
abort "usage: build_pack_stream.rb <staged_dir> <out.pack>" unless staged && out
abort "no such directory: #{staged}" unless File.directory?(staged)

root = File.expand_path(staged)
files = []
Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).sort.each do |p|
  next unless File.file?(p)
  base = File.basename(p)
  if SKIP.any? { |re| base =~ re }
    warn "skipping backup file: #{base}"
    next
  end
  internal = p[(root.length + 1)..].tr("/", "\\").downcase
  files << [internal, p, File.size(p)]
end
abort "nothing to pack" if files.empty?

index = String.new(capacity: files.sum { |f| f[0].bytesize + 5 })
files.each { |internal, _, size| index << [size].pack("l<") << internal.b << "\0" }

total = files.sum { |f| f[2] }
File.open(out, "wb") do |o|
  o << "PFH0"
  o << [4].pack("l<")                 # mod_type 4 = movie, auto-loads from data\
  o << [0].pack("l<")                 # deps_count
  o << [0].pack("l<")                 # deps_len
  o << [files.size].pack("l<")
  o << [index.bytesize].pack("l<")
  o << index
  files.each do |_, path, _size|
    File.open(path, "rb") { |i| IO.copy_stream(i, o) }
  end
end

puts "#{files.size} files, #{'%.1f' % (total / 1024.0 / 1024)} MB -> #{out}"
puts "  pack size #{'%.1f' % (File.size(out) / 1024.0 / 1024)} MB"

# verify the index we just wrote actually resolves: walk it back and check the
# last entry lands exactly at end-of-file. An off-by-one in the header is the
# classic way to produce a pack that looks fine and reads garbage.
File.open(out, "rb") do |f|
  raise "magic" unless f.read(4) == "PFH0"
  _t, _dc, dl, nf, il = f.read(20).unpack("l<5")
  f.read(dl); idx = f.read(il)
  pos = 0; off = 24 + dl + il
  nf.times do
    sz = idx[pos, 4].unpack1("l<"); pos += 4
    nul = idx.index("\x00", pos); pos = nul + 1
    off += sz
  end
  raise "index does not account for the file (#{off} vs #{File.size(out)})" unless off == File.size(out)
  puts "  index verified: #{nf} entries account for every byte"
end
