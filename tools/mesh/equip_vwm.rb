# equip_vwm.rb - reader/writer for unitmodels\euro_equipment.variant_weighted_mesh,
# the single file that holds EVERY weapon and every piece of worn kit in the game.
#
# WHY THIS FILE NEEDED ITS OWN TOOL
#   vwm.rb parses it "successfully" as a mesh with 0 parts and round-trips it
#   byte-identically - while putting 1,610,160 of its 1,610,592 bytes into the
#   `trailer` field, which the reader never interprets and the writer copies
#   back verbatim. A round-trip through an uninterpreted field is free and
#   proves nothing. The file is not empty: it is a CONTAINER of 134 sub-models.
#
#   The lesson generalises:A trailer holding 99.97% of the input should fail the read outright.
#
# LAYOUT
#   [ vwm header, genuinely 0 parts ]     <- read/written by vwm.rb
#   u4 sub_count                          <- 134
#   sub_count x sub-model, back to back:
#       magic 78 56 34 12
#       u4   version                      <- 5 on every one
#       str  name                         <- "rigid_equip_euro_musket01", ...
#       u4   unknown                      <- 1 on every one
#       textures, repeated:
#           u2 == 0  -> consume 2 bytes, list ends
#           else     -> u1 flag, then str  ("equip_diffuse", "equip_normal", ...)
#       u4 n, n x (str, f4)               <- scalar shader params, as in vwm
#       u4 n, n x (str, 16 bytes)         <- vec4 params, as in vwm
#       u4 vertex_count
#       vertex_count x 80 bytes           <- 20 floats. NOT the vwm vertex.
#       u4 index_count
#       index_count x u4                  <- 32-bit, as in vwm
#
#   `str` is u2 character count + UTF-16LE, the same as vwm.
#
# THE VERTEX IS NOT THE vwm VERTEX. Equipment is RIGID - it hangs off a single
# Weapon bone and has no per-vertex influence blocks at all, so none of the
# bone-space machinery in vwm.rb/vwm_pose.rb applies here. 20 flat floats.
#
# THE TEXTURE LIST TERMINATOR cost the most time. Entries read as [u1][str],
# but the list does NOT end with an empty [u1][str] - it ends with a bare
# u2 = 0. Test u2(p) BEFORE consuming the flag byte, or the length is read one
# byte off and comes back as 2816.
#
# Usage
#   ruby equip_vwm.rb info      <file>            parts, counts, totals
#   ruby equip_vwm.rb roundtrip <file>            the gate: byte-identical?

module EquipVWM
  MAGIC = "\x78\x56\x34\x12".b

  class R
    attr_reader :pos
    def initialize(d) = (@d = d; @pos = 0)
    def u2 = (v = @d[@pos, 2].unpack1("v"); @pos += 2; v)
    def u4 = (v = @d[@pos, 4].unpack1("V"); @pos += 4; v)
    def raw(n) = (v = @d[@pos, n]; @pos += n; v)
    def peek2 = @d[@pos, 2].unpack1("v")
    def str = (n = u2; raw(n * 2))
    def eof? = @pos >= @d.bytesize
  end

  class W
    def initialize = (@o = "".b)
    def u2(v) = (@o << [v].pack("v"); self)
    def u4(v) = (@o << [v].pack("V"); self)
    def raw(b) = (@o << b.to_s.b; self)
    def str(b) = (u2(b.bytesize / 2).raw(b))
    def to_s = @o
  end

  def self.read(trailer)
    r = R.new(trailer)
    n = r.u4
    subs = Array.new(n) { read_sub(r) }
    { count: n, subs: subs, tail: trailer[r.pos..] }
  end

  def self.read_sub(r)
    raise "bad sub-model magic at #{r.pos}" unless r.raw(4) == MAGIC
    s = { version: r.u4, name: r.str, unknown: r.u4, texs: [] }
    loop do
      if r.peek2 == 0
        r.raw(2)
        break
      end
      flag = r.raw(1)
      s[:texs] << [flag, r.str]
    end
    s[:scalars] = Array.new(r.u4) { [r.str, r.raw(4)] }
    s[:vec4s]   = Array.new(r.u4) { [r.str, r.raw(16)] }
    vc = r.u4
    s[:verts] = Array.new(vc) { r.raw(80) }
    ic = r.u4
    s[:idx] = r.raw(ic * 4)
    s
  end

  def self.write(m)
    w = W.new
    w.u4(m[:subs].size)
    m[:subs].each { |s| write_sub(w, s) }
    w.raw(m[:tail])
    w.to_s
  end

  def self.write_sub(w, s)
    w.raw(MAGIC).u4(s[:version]).str(s[:name]).u4(s[:unknown])
    s[:texs].each { |flag, nm| w.raw(flag).str(nm) }
    w.u2(0)
    w.u4(s[:scalars].size); s[:scalars].each { |nm, v| w.str(nm).raw(v) }
    w.u4(s[:vec4s].size);   s[:vec4s].each   { |nm, v| w.str(nm).raw(v) }
    w.u4(s[:verts].size);   s[:verts].each   { |v| w.raw(v) }
    w.u4(s[:idx].bytesize / 4).raw(s[:idx])
  end

  def self.name_of(s) = s[:name].encode("UTF-8", "UTF-16LE")
  def self.floats(v)  = v.unpack("e20")
end

if $0 == __FILE__
  require_relative "vwm"
  cmd, path = ARGV
  abort "usage: equip_vwm.rb [info|roundtrip] <file>" unless cmd && path

  raw   = File.binread(path)
  outer = VWM.read(raw)
  m     = EquipVWM.read(outer[:trailer])

  case cmd
  when "info"
    tv = m[:subs].sum { |s| s[:verts].size }
    ti = m[:subs].sum { |s| s[:idx].bytesize / 4 }
    puts "sub-models  : #{m[:subs].size}"
    puts "vertices    : #{tv}"
    puts "triangles   : #{ti / 3}"
    puts "unparsed    : #{m[:tail].bytesize} bytes"
    puts
    m[:subs].sort_by { |s| -s[:verts].size }.each do |s|
      printf("  %-34s verts=%5d tris=%5d\n",
             EquipVWM.name_of(s), s[:verts].size, s[:idx].bytesize / 12)
    end
  when "roundtrip"
    back = VWM.write(outer.merge(trailer: EquipVWM.write(m)))
    if back == raw
      puts "BYTE-IDENTICAL  (#{raw.bytesize} bytes, #{m[:subs].size} sub-models)"
      puts "unparsed tail: #{m[:tail].bytesize} bytes"
    else
      i = (0...[back.bytesize, raw.bytesize].min).find { |k| back[k] != raw[k] }
      abort "DIFFERS at byte #{i} (out #{back.bytesize} vs in #{raw.bytesize})"
    end
  else
    abort "unknown command #{cmd}"
  end
end
