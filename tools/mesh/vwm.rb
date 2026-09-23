# vwm.rb - reader AND writer for Empire's .variant_weighted_mesh (unit
# geometry). Phase 2 of the high-poly units plan.
#
# THE FORMAT (proven across 1021 files / 2,585,140 vertices)
#
#   magic 78 56 34 12
#   u4                                        version-ish, always 1 so far
#   u4 n1, n1 x (u2 len + UTF-16LE name, f4)  scalar shader params
#   u4 n2, n2 x (name, f4 x 4)                vec4 shader params
#   u4 n3, n3 x (name, u4 vcount, u4 icount)  part table
#   per part, back to back:
#     [u4 vertex_count]
#     vertices, each:
#        8 floats                             position at [0..2]
#        u4 influence_count
#        influence_count x ( u4 bone, 6 floats, f4 weight )   32 bytes each
#        4 x u4 tail
#     [u4 index_count]
#     index_count x u4                        32-BIT indices
#
#   vertex_size = 52 + 32 * influence_count   (1 -> 84, 2 -> 116)
#
# WHY FLOATS ARE KEPT AS RAW u32
#   The gate for this format is a BYTE-IDENTICAL repack, and decoding to Ruby
#   Float and back can lose that: NaN payloads, signalling NaNs and negative
#   zero do not survive a naive round-trip. Every float field is therefore
#   carried as its raw 32-bit pattern and only converted on demand, so the
#   writer is bit-exact by construction rather than by luck.
#
# Usage
#   ruby vwm.rb roundtrip [--limit N]    # repack every mesh, require identical
#   ruby vwm.rb info <file>              # summarise one mesh

require_relative "../../empire_paths"

module VWM
  MAGIC = "\x78\x56\x34\x12".b

  class Reader
    attr_reader :pos
    def initialize(d) = (@d = d; @pos = 0)
    def u4  = (v = @d[@pos, 4].unpack1("V"); @pos += 4; v)
    def raw(n) = (v = @d[@pos, n]; @pos += n; v)
    def str
      len = @d[@pos, 2].unpack1("v"); @pos += 2
      s = @d[@pos, len * 2]; @pos += len * 2
      s
    end
    def rest = @d[@pos..]
  end

  class Writer
    def initialize = (@out = "".b)
    def u4(v) = (@out << [v].pack("V"); self)
    def raw(b) = (@out << b.to_s.b; self)
    def str(b) = (@out << [b.bytesize / 2].pack("v") << b.b; self)
    def to_s = @out
  end

  # Everything is stored as raw bytes / integers so a repack is bit-exact.
  def self.read(d)
    raise "bad magic" unless d[0, 4] == MAGIC
    r = Reader.new(d)
    r.raw(4)
    m = { version: r.u4 }
    m[:scalars] = Array.new(r.u4) { [r.str, r.raw(4)] }
    m[:vec4s]   = Array.new(r.u4) { [r.str, r.raw(16)] }
    m[:parts]   = Array.new(r.u4) { { name: r.str, vc: r.u4, ic: r.u4 } }
    m[:parts].each do |p|
      vc = r.u4
      raise "vertex count #{vc} != table #{p[:vc]}" unless vc == p[:vc]
      p[:verts] = Array.new(vc) do
        head = r.raw(32)
        n = r.u4
        raise "implausible influence count #{n}" if n < 1 || n > 8
        infl = Array.new(n) { { bone: r.u4, mid: r.raw(24), weight: r.raw(4) } }
        { head: head, infl: infl, tail: r.raw(16) }
      end
      ic = r.u4
      raise "index count #{ic} != table #{p[:ic]}" unless ic == p[:ic]
      p[:idx] = r.raw(ic * 4)
    end
    m[:trailer] = r.rest
    m
  end

  def self.write(m)
    w = Writer.new
    w.raw(MAGIC).u4(m[:version])
    w.u4(m[:scalars].size); m[:scalars].each { |n, v| w.str(n).raw(v) }
    w.u4(m[:vec4s].size);   m[:vec4s].each   { |n, v| w.str(n).raw(v) }
    w.u4(m[:parts].size)
    m[:parts].each { |p| w.str(p[:name]).u4(p[:vc]).u4(p[:ic]) }
    m[:parts].each do |p|
      w.u4(p[:vc])
      p[:verts].each do |v|
        w.raw(v[:head]).u4(v[:infl].size)
        v[:infl].each { |i| w.u4(i[:bone]).raw(i[:mid]).raw(i[:weight]) }
        w.raw(v[:tail])
      end
      w.u4(p[:ic]).raw(p[:idx])
    end
    w.raw(m[:trailer])
    w.to_s
  end

  # GEOMETRY LIVES IN THE INFLUENCE BLOCKS, NOT THE VERTEX HEAD.
  #
  # The head's first two floats are TEXTURE COORDINATES, not position. Proof:
  # the four head variants of euro_line_infantry occupy v bands 0.00-0.18,
  # 0.19-0.37, 0.38-0.56 and 0.57-0.75, and the tricorne hats tile in u at
  # 0.00-0.25 / 0.25-0.50 - that is an atlas, and no skeleton puts four heads
  # in four horizontal bands.
  #
  # Each 32-byte influence is instead:
  #     [u4 bone][3 f4 position IN THAT BONE'S SPACE][3 f4 normal][f4 weight]
  # Verified across euro_line_infantry: 6435/6435 normals are unit length and
  # 4980/4980 vertices have weights summing to 1.0.
  #
  # So the mesh is BONE-SPACE SKINNED: the rendered position is
  #     sum over influences of  weight * (bone_matrix * bone_space_position)
  # and moving a vertex means editing it consistently in every influence.
  def self.uv(vertex)          = vertex[:head][0, 8].unpack("e2")
  def self.infl_pos(i)         = i[:mid][0, 12].unpack("e3")
  def self.infl_normal(i)      = i[:mid][12, 12].unpack("e3")
  def self.infl_weight(i)      = i[:weight].unpack1("e")
  def self.set_infl_pos(i, xyz) = (i[:mid] = xyz.pack("e3") + i[:mid][12..])
end

# ---------------------------------------------------------------- driver ----
if $PROGRAM_NAME == __FILE__
  mode = ARGV[0]
  def each_pack_entry(path)
    File.open(path, "rb") do |f|
      return unless f.read(4) == "PFH0"
      _t, _dc, deps_len, nfiles, index_len = f.read(20).unpack("l<5")
      f.read(deps_len); index = f.read(index_len)
      pos = 0; offset = 24 + deps_len + index_len
      nfiles.times do
        size = index[pos, 4].unpack1("l<"); pos += 4
        nul = index.index("\x00", pos); name = index[pos...nul]; pos = nul + 1
        yield name, offset, size, f
        offset += size
      end
    end
  end

  case mode
  when "info"
    d = File.binread(ARGV[1])
    m = VWM.read(d)
    puts "parts: #{m[:parts].size}"
    m[:parts].each do |p|
      hist = Hash.new(0)
      p[:verts].each { |v| hist[v[:infl].size] += 1 }
      nm = p[:name].force_encoding("UTF-16LE").encode("UTF-8")
      puts format("  %-40s v=%-6d tris=%-6d influences: %s",
                  nm, p[:vc], p[:ic] / 3, hist.sort.map { |k, v| "#{k}:#{v}" }.join(" "))
    end
    puts "repack byte-identical: #{VWM.write(m) == d}"
  when "roundtrip"
    limit = (i = ARGV.index("--limit")) ? ARGV[i + 1].to_i : 0
    game = EMPIRE.game
    n = ok = 0
    bad = []
    infl_hist = Hash.new(0)
    Dir[File.join(game, "data", "*.pack")].sort.each do |pk|
      each_pack_entry(pk) do |name, off, size, f|
        next unless name.downcase.end_with?(".variant_weighted_mesh")
        next if limit > 0 && n >= limit
        here = f.pos; f.seek(off); d = f.read(size); f.seek(here)
        next unless d[0, 4] == VWM::MAGIC          # DLC is encrypted; skip
        n += 1
        begin
          m = VWM.read(d)
          m[:parts].each { |p| p[:verts].each { |v| infl_hist[v[:infl].size] += 1 } }
          if VWM.write(m) == d
            ok += 1
          else
            bad << [File.basename(name), "not identical"]
          end
        rescue => e
          bad << [File.basename(name), e.message]
        end
      end
    end
    puts "=" * 70
    puts "round-tripped #{ok}/#{n} meshes BYTE-IDENTICALLY"
    puts "influence count distribution: " +
         infl_hist.sort.map { |k, v| "#{k}:#{v}" }.join("  ")
    unless bad.empty?
      puts "\nfailures (#{bad.size}):"
      bad.first(20).each { |nm, why| puts "  #{nm}  #{why}" }
    end
  else
    puts "usage: ruby vwm.rb roundtrip [--limit N] | info <file>"
  end
end
