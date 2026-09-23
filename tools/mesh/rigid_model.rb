# rigid_model.rb - reader/writer for `.rigid_model`: every building, fort,
# tree, prop and engine model in the game. 4,106 files, 929 MB.
#
# RELATIONSHIP TO THE WEAPON CONTAINER
#   `euro_equipment.variant_weighted_mesh` (see equip_vwm.rb) turned out to be
#   a list of sub-models sharing the `78 56 34 12` magic. `.rigid_model` is the
#   SAME sub-model format with ONE field removed - it has no per-sub-model
#   name - wrapped directly in a [u4 mesh_count] header instead of behind a vwm
#   header. Reusing equip_vwm.rb directly parses the first sub-model and then
#   desynchronises at the second, which is exactly what a near-miss format
#   looks like and why the corpus gate matters more than one happy file.
#
# LAYOUT
#   [u4 mesh_count]
#   mesh_count x:
#       magic 78 56 34 12
#       u4  version                 5 on everything seen so far
#       textures, repeated:
#           u2 == 0 -> consume 2 bytes, list ends
#           else    -> u1 flag, then str        (diffuse / normal / gloss_map)
#       u4 n, n x (str, f4)         scalar shader params
#       u4 n, n x (str, 16 bytes)   vec4 params
#       u4 vertex_count, vertex_count x 80      <- 20 floats, as equipment
#       u4 index_count,  index_count  x u4
#   [trailer]
#
#   `str` is u2 character count + UTF-16LE.
#
# THE VERTEX is the rigid 20-float one, NOT the skinned vwm vertex:
#   f0-2 position | f3-5 normal | f6-7 uv | f8-10 tangent | f11-13 binormal
#   f14-17 colour | f18-19 per-sub-model constants
# There are no influence blocks - buildings do not deform - so the Phong
# tessellation in subdiv_equip.rb applies directly and none of the bone-space
# machinery does.
#
# Usage
#   ruby rigid_model.rb info      <file>
#   ruby rigid_model.rb roundtrip <file>
#   ruby rigid_model.rb corpus              # gate every .rigid_model in every pack

require_relative "../../empire_paths"

module RigidModel
  MAGIC = "\x78\x56\x34\x12".b

  class R
    attr_reader :pos
    attr_accessor :piece_field, :variant
    def initialize(d, piece_field = false) = (@d = d; @pos = 0; @piece_field = piece_field)
    def u2 = (v = @d[@pos, 2].unpack1("v"); @pos += 2; v)
    def u4 = (v = @d[@pos, 4].unpack1("V"); @pos += 4; v)
    def raw(n) = (v = @d[@pos, n]; @pos += n; v)
    def peek2 = @d[@pos, 2].unpack1("v")
    def str = (n = u2; raw(n * 2))
    def left = @d.bytesize - @pos
  end

  class W
    def initialize = (@o = "".b)
    def u2(v) = (@o << [v].pack("v"); self)
    def u4(v) = (@o << [v].pack("V"); self)
    def raw(b) = (@o << b.to_s.b; self)
    def str(b) = (u2(b.bytesize / 2).raw(b))
    def to_s = @o
  end

  # THREE WRAPPERS, and the sub-model differs with them.
  #   :plain  `.rigid_model` / `.animatable_rigid_model`
  #           [u4 count] then UNNAMED sub-models, texture list ends on u2 == 0
  #   :naval  `.rigid_naval_model`
  #           [u4 count][str group] then NAMED sub-models with EXACTLY THREE
  #           flagged textures followed by a BARE string - an ambient-occlusion
  #           map that is a separate field, not a fourth list entry, and so has
  #           no flag byte and no u2 == 0 terminator after it.
  #           Verified identical across 435 sub-models in three different ships
  #           before being written down; one ship cannot distinguish "fixed at
  #           three" from "terminated differently".
  def self.read(d, piece_field: false, variant: :plain)
    r = R.new(d, piece_field)
    r.variant = variant
    n = r.u4
    raise "implausible mesh count #{n}" if n < 1 || n > 4096
    subs = Array.new(n) { read_sub(r) }
    { count: n, variant: variant, subs: subs, tail: d[r.pos..] }
  end

  # VERSION 4 CARRIES ONE EXTRA u32 PER SUB-MODEL, after the indices.
  # Found on `.animatable_rigid_model` (the working artillery pieces): the v5
  # grammar read one index too many and desynchronised at the next magic. The
  # tell was arithmetic, not a crash - the implied index count was 2197 while
  # the stored one was 2196, and only 2196 divides by 3. The values seen are
  # small ordinals (1,2,3,4) per sub-model, consistent with the animated piece
  # index: an animatable gun moves barrel, wheels and carriage separately.
  def self.read_sub(r)
    # NAVAL: each sub-model is PRECEDED by its own name string. That is why the
    # file appears to open with [u4 count][str "display"] - the "display" is not
    # a file-level group, it belongs to sub-model 0. Missing this leaves 14, 22
    # or 16 bytes unaccounted for between sub-models, which is exactly
    # [u2 len][UTF-16] for a 6, 10 or 7 character name.
    s = {}
    s[:pre] = r.str if r.variant == :naval
    raise "bad sub-model magic at #{r.pos}" unless r.raw(4) == MAGIC
    s[:version] = r.u4
    s[:texs] = []
    if r.variant == :naval
      s[:name] = r.str
      3.times { flag = r.raw(1); s[:texs] << [flag, r.str] }
      s[:ao] = r.str
    else
      loop do
        break (r.raw(2); nil) if r.peek2 == 0
        flag = r.raw(1)
        s[:texs] << [flag, r.str]
      end
    end
    s[:scalars] = Array.new(r.u4) { [r.str, r.raw(4)] }
    s[:vec4s]   = Array.new(r.u4) { [r.str, r.raw(16)] }
    s[:pre2] = r.raw(8) if r.variant == :naval    # two u32, observed 0 and 1
    vc = r.u4
    raise "implausible vertex count #{vc}" if vc > 4_000_000
    s[:verts] = Array.new(vc) { r.raw(80) }
    s[:gap] = r.raw(16) if r.variant == :naval   # 16 zero bytes before the indices
    ic = r.u4
    raise "implausible index count #{ic}" if ic > 12_000_000
    s[:idx] = r.raw(ic * 4)
    s[:piece] = r.raw(4) if r.piece_field
    s
  end

  # THE TRAILING u32 BELONGS TO THE FILE TYPE, NOT THE SUB-MODEL VERSION.
  # Keying it off `version <= 4` looked right on one cannon and broke 602
  # `.rigid_model` files that had been round-tripping - plain models contain v4
  # sub-models WITHOUT the field. Rather than infer it, parse both ways and
  # keep whichever reproduces the input byte for byte. That is self-proving:
  # a wrong guess cannot round-trip 80-byte vertices and 4-byte indices by luck.
  def self.read_auto(d)
    [[:plain,false],[:plain,true],[:naval,false],[:naval,true]].each do |va, pf|
      begin
        m = read(d, piece_field: pf, variant: va)
        return m if write(m) == d
      rescue StandardError
        next
      end
    end
    raise "neither layout reproduces this file"
  end

  def self.write(m)
    w = W.new
    w.u4(m[:subs].size)
    m[:subs].each { |s| write_sub(w, s, m[:variant]) }
    w.raw(m[:tail])
    w.to_s
  end

  def self.write_sub(w, s, variant = :plain)
    w.str(s[:pre]) if variant == :naval
    w.raw(MAGIC).u4(s[:version])
    if variant == :naval
      w.str(s[:name])
      s[:texs].each { |flag, nm| w.raw(flag).str(nm) }
      w.str(s[:ao])
    else
      s[:texs].each { |flag, nm| w.raw(flag).str(nm) }
      w.u2(0)
    end
    w.u4(s[:scalars].size); s[:scalars].each { |nm, v| w.str(nm).raw(v) }
    w.u4(s[:vec4s].size);   s[:vec4s].each   { |nm, v| w.str(nm).raw(v) }
    w.raw(s[:pre2]) if s[:pre2]
    w.u4(s[:verts].size);   s[:verts].each   { |v| w.raw(v) }
    w.raw(s[:gap]) if s[:gap]
    w.u4(s[:idx].bytesize / 4).raw(s[:idx])
    w.raw(s[:piece]) if s[:piece]
  end

  def self.tex_of(s) = s[:texs].map { |_, n| n.encode("UTF-8", "UTF-16LE") }
end

if $0 == __FILE__
  GAME = EMPIRE.game

  def each_pack_entry(pk)
    File.open(pk, "rb") do |f|
      return unless f.read(4) == "PFH0"
      _t, _dc, dl, nf, il = f.read(20).unpack("l<5")
      f.read(dl); idx = f.read(il); pos = 0; off = 24 + dl + il
      ents = []
      nf.times do
        sz = idx[pos, 4].unpack1("l<"); pos += 4
        nul = idx.index("\x00", pos); ents << [idx[pos...nul], off, sz]; off += sz; pos = nul + 1
      end
      ents.each { |name, o, sz| yield name, o, sz, f }
    end
  end

  case ARGV[0]
  when "info", "roundtrip"
    d = File.binread(ARGV[1])
    m = RigidModel.read_auto(d)
    v = m[:subs].sum { |s| s[:verts].size }
    t = m[:subs].sum { |s| s[:idx].bytesize / 12 }
    puts "#{File.basename(ARGV[1])}: #{m[:subs].size} sub-models, #{v} verts, #{t} tris, tail #{m[:tail].bytesize} b"
    if ARGV[0] == "roundtrip"
      back = RigidModel.write(m)
      puts back == d ? "  BYTE-IDENTICAL" : "  DIFFERS"
      exit(back == d ? 0 : 1)
    else
      m[:subs].each_with_index { |s, i|
        puts "  [%2d] v%d  %6d verts %6d tris  %s" %
             [i, s[:version], s[:verts].size, s[:idx].bytesize / 12, RigidModel.tex_of(s).first] }
    end
  when "corpus"
    ok = 0; bad = Hash.new(0); files = 0; verts = 0; tris = 0; bytes = 0
    Dir["#{GAME}/data/*.pack"].sort.each do |pk|
      next if File.basename(pk).start_with?("zz_")
      each_pack_entry(pk) do |name, o, sz, f|
        next unless name.downcase.end_with?(".rigid_model")
        files += 1
        f.seek(o); d = f.read(sz)
        begin
          m = RigidModel.read(d)
          if RigidModel.write(m) == d
            ok += 1
            verts += m[:subs].sum { |s| s[:verts].size }
            tris  += m[:subs].sum { |s| s[:idx].bytesize / 12 }
            bytes += sz
          else
            bad["not byte-identical"] += 1
          end
        rescue => e
          bad[e.message.sub(/ at \d+/, " at N").sub(/\d+/, "N")] += 1
        end
      end
    end
    puts "rigid_model corpus: #{ok}/#{files} byte-identical"
    puts "  #{verts} verts, #{tris} tris, #{bytes / 1024 / 1024} MB parsed"
    bad.sort_by { |_, v| -v }.each { |k, v| puts "  %5d  %s" % [v, k] } if bad.any?
  else
    abort "usage: rigid_model.rb [info|roundtrip] <file> | corpus"
  end
end
