# validate_vwm.rb - Phase 0 of the high-poly units plan: check that the
# decoded .variant_weighted_mesh layout holds across the WHOLE corpus, not
# just the one mesh it was derived from.
#
# WHY
#   A format reveals its variability across samples, not within one,
#   and every later phase assumes the container is
#   uniform. Any file that does not chain is a variant to understand NOW
#   rather than a mystery after a writer has been built on the assumption.
#
# THE MODEL UNDER TEST
#   magic 78 56 34 12
#   u4
#   u4 n1, n1 x (u2 len + UTF-16LE name, f4)          scalar params
#   u4 n2, n2 x (name, f4 x 4)                        vec4 params
#   u4 n3, n3 x (name, u4 vcount, u4 icount)          part table
#   then per part, back to back:
#     [u4 vcount][vertices, VARIABLE][u4 icount][indices u4]
#
#   Vertex size is not yet known, so the index block is LOCATED rather than
#   computed: scan forward, 4-byte aligned, for the part's index count, and
#   accept a candidate only if skipping icount*4 bytes lands on the NEXT
#   part's vertex count (or on EOF for the last part). That mutual constraint
#   is what makes a chain meaningful instead of a lucky match on a float that
#   happens to equal the index count.
#
# Reads directly from the .pack files - 1,269 meshes are not worth extracting.
#
# Usage
#   ruby validate_vwm.rb [--game DIR] [--limit N] [--verbose]

require_relative "../../../empire_paths"

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
game    = opt("game", EMPIRE.game)
limit   = opt("limit", "0").to_i
verbose = ARGV.include?("--verbose")

# ---- PFH0 pack reader ------------------------------------------------------
# Layout: "PFH0", type i32, deps_count i32, deps_len i32, files i32,
# index_len i32, [deps], [index: i32 size + ASCII path + NUL], [blobs].
# Data starts at 24 + deps_len + index_len - skipping the dependency block is
# the classic way to get offsets wrong by exactly deps_len bytes.
def each_pack_entry(path)
  File.open(path, "rb") do |f|
    return unless f.read(4) == "PFH0"
    _type, _dc, deps_len, nfiles, index_len = f.read(20).unpack("l<5")
    f.read(deps_len)
    index = f.read(index_len)
    pos = 0
    offset = 24 + deps_len + index_len
    nfiles.times do
      size = index[pos, 4].unpack1("l<"); pos += 4
      nul = index.index("\x00", pos)
      name = index[pos...nul]
      pos = nul + 1
      yield name, offset, size, f
      offset += size
    end
  end
end

# ---- the validator ---------------------------------------------------------
def u4(d, p) = [d[p, 4].unpack1("V"), p + 4]
def u2(d, p) = [d[p, 2].unpack1("v"), p + 2]
def rstr(d, p)
  len, p = u2(d, p)
  return [nil, p] if len.nil? || len > 500
  s = d[p, len * 2].to_s
  [s.force_encoding("UTF-16LE").encode("UTF-8", invalid: :replace, undef: :replace), p + len * 2]
end

def validate(d)
  return [:bad_magic, nil] unless d[0, 4] == "\x78\x56\x34\x12".b
  p = 4
  _v, p = u4(d, p)
  n1, p = u4(d, p)
  return [:bad_param_count, n1] if n1.nil? || n1 > 500
  n1.times { _s, p = rstr(d, p); p += 4 }
  n2, p = u4(d, p)
  return [:bad_vec4_count, n2] if n2.nil? || n2 > 500
  n2.times { _s, p = rstr(d, p); p += 16 }
  n3, p = u4(d, p)
  # 0 parts is LEGAL: `euro_equipment.variant_weighted_mesh` has valid magic
  # and an empty part table, and round-trips byte-identically. Rejecting it as
  # malformed was this validator's error, not the file's.
  return [:bad_part_count, n3] if n3.nil? || n3 > 500
  parts = []
  n3.times do
    nm, p = rstr(d, p)
    return [:bad_part_name, nil] if nm.nil?
    vc, p = u4(d, p)
    ic, p = u4(d, p)
    return [:bad_counts, "#{vc}/#{ic}"] if vc.nil? || ic.nil? || vc > 5_000_000 || ic > 20_000_000 || ic % 3 != 0
    parts << [nm, vc, ic]
  end

  # VERTEX SIZE IS NOW KNOWN, so vertices are walked EXACTLY rather than the
  # index block being searched for. Each vertex is
  #     9 header slots, then `count` influence blocks of 8 slots
  #     ([bone u4][6 floats][weight f4]), then a 4-slot zero tail
  # i.e.  size = 52 + 32 * influence_count   (count 1 -> 84, count 2 -> 116)
  # Landing precisely on the index count for every part of every file is a far
  # stronger proof than finding a u4 that happens to equal it.
  at = p
  parts.each_with_index do |(_nm, vc, ic), i|
    got, at2 = u4(d, at)
    return [:vcount_mismatch, "part #{i}: #{got} != #{vc}"] unless got == vc
    v = at2
    vc.times do |k|
      return [:vertex_overrun, "part #{i} vertex #{k}"] if v + 36 > d.bytesize
      c, _ = u4(d, v + 32)
      return [:bad_influence_count, "part #{i} vertex #{k}: #{c}"] if c.nil? || c < 1 || c > 8
      v += 52 + 32 * c
    end
    gotic, v2 = u4(d, v)
    return [:icount_mismatch, "part #{i}: #{gotic} != #{ic}"] unless gotic == ic
    at = v2 + ic * 4
  end
  tail = d.bytesize - at
  return [:tail, tail] unless tail.between?(0, 64)
  [:ok, { parts: parts.size, verts: parts.sum { |x| x[1] }, tris: parts.sum { |x| x[2] } / 3, tail: tail }]
end

# ---- run over every pack ---------------------------------------------------
packs = Dir[File.join(game, "data", "*.pack")].sort
stats = Hash.new(0)
fails = []
total_v = 0
total_t = 0
n = 0

packs.each do |pk|
  each_pack_entry(pk) do |name, offset, size, f|
    next unless name.downcase.end_with?(".variant_weighted_mesh")
    next if limit > 0 && n >= limit
    n += 1
    here = f.pos
    f.seek(offset)
    data = f.read(size)
    f.seek(here)
    kind, info = validate(data)
    stats[kind] += 1
    if kind == :ok
      total_v += info[:verts]
      total_t += info[:tris]
      puts format("  ok   %-58s parts=%-3d verts=%-6d tris=%-6d tail=%d",
                  File.basename(name), info[:parts], info[:verts], info[:tris], info[:tail]) if verbose
    else
      fails << [File.basename(pk), name, kind, info]
    end
  end
end

puts "=" * 78
puts "checked #{n} .variant_weighted_mesh files across #{packs.size} packs"
stats.sort_by { |_, v| -v }.each { |k, v| puts format("  %-20s %d", k, v) }
if n > 0
  pct = (stats[:ok] * 100.0 / n).round(2)
  puts "\nlayout holds on #{stats[:ok]}/#{n}  (#{pct}%)"
  puts "total geometry in the corpus: #{total_v} vertices, #{total_t} triangles"
end
unless fails.empty?
  puts "\nfailures (first 25):"
  fails.first(25).each { |pk, nm, k, i| puts format("  %-14s %-56s %s %s", pk, File.basename(nm), k, i) }
  byk = fails.group_by { |x| x[2] }
  puts "\nfailure shapes: " + byk.map { |k, v| "#{k}=#{v.size}" }.join("  ")
end
