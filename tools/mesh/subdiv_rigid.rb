# subdiv_rigid.rb - Phong tessellation for `.rigid_model`: buildings, forts,
# props. Uses the same core as the weapons (subdiv_prop_lib.rb) but with a
# MUCH tighter smoothness threshold, because architecture is not a musket.
#
# WHY THE THRESHOLD MOVES
#   Measured over 40 building lod01 models, 118,432 unique edges:
#
#     0-10 deg  flat or near-flat            18.2%   subdividing changes nothing
#    10-25 deg  gentle curve                  8.1%
#    25-45 deg  real curvature               19.4%   <- worth rounding
#    45-60 deg  SOFT CORNER                  14.5%   <- window reveals, buttresses
#      >60 deg  architectural crease         39.7%   already left alone
#
#   The weapons threshold (60 deg) would round that 14.5% band. On a soldier
#   rounding a 50-degree angle is correct; on masonry it turns a crisp window
#   reveal into something melted. Default here is 30 deg (dot 0.866), which
#   keeps the 25-45 band and hard-stops everything above it.
#
#   This is the same mistake as Loop-on-weapons, inverted: the previous error
#   was smoothing a hard surface too little and shrinking it, this one would be
#   smoothing a hard surface that should stay sharp.
#
# WHAT THIS DOES NOT TOUCH
#   Original vertices never move, so every silhouette and every join between
#   building pieces is preserved exactly. Only new edge midpoints are placed.
#
# Usage
#   ruby subdiv_rigid.rb <in.rigid_model> <out> [--deg 30] [--plan]
#   ruby subdiv_rigid.rb --scan <substring>      # cost a category before doing it

require_relative "rigid_model"
require_relative "subdiv_prop_lib"

require_relative "../../../empire_paths"

GAME = EMPIRE.game

def deg_to_dot(d) = Math.cos(d * Math::PI / 180.0)

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

if ARGV[0] == "--scan"
  needle = ARGV[1].to_s.downcase
  abort "usage: subdiv_rigid.rb --scan <substring>" if needle.empty?
  files = 0; v = 0; t = 0; b = 0
  Dir["#{GAME}/data/*.pack"].sort.each do |pk|
    next if File.basename(pk).start_with?("zz_")
    each_pack_entry(pk) do |name, o, sz, f|
      nl = name.downcase
      next unless nl.end_with?(".rigid_model") && nl.include?(needle)
      f.seek(o); d = f.read(sz)
      begin
        m = RigidModel.read(d); next unless RigidModel.write(m) == d
      rescue; next; end
      files += 1
      v += m[:subs].sum { |s| s[:verts].size }
      t += m[:subs].sum { |s| s[:idx].bytesize / 12 }
      b += sz
    end
  end
  puts "match '#{needle}': #{files} files, #{v} verts, #{t} tris, #{'%.1f' % (b/1024.0/1024)} MB"
  puts "  at 4x triangles that becomes roughly #{'%.1f' % (b*3.5/1024.0/1024)} MB"
  exit
end

inp, out = ARGV[0], ARGV[1]
plan = ARGV.include?("--plan")
abort "usage: subdiv_rigid.rb <in> <out> [--deg N] [--plan]" unless inp && (out || plan)
i = ARGV.index("--deg"); deg = i ? ARGV[i + 1].to_f : 30.0
dot = deg_to_dot(deg)

d = File.binread(inp)
m = RigidModel.read(d)
abort "refusing: this file does not round-trip" unless RigidModel.write(m) == d

bv = m[:subs].sum { |s| s[:verts].size }
bt = m[:subs].sum { |s| s[:idx].bytesize / 12 }
m[:subs] = m[:subs].map { |s| subdivide_sub(s, smooth_dot: dot, max_bulge: MAX_BULGE) }
av = m[:subs].sum { |s| s[:verts].size }
at = m[:subs].sum { |s| s[:idx].bytesize / 12 }

# gates: nothing may move that was already there, and no index may dangle
moved = 0; bad = 0
orig = RigidModel.read(d)
m[:subs].each_with_index do |s, k|
  o = orig[:subs][k]
  o[:verts].each_index { |j| moved += 1 if o[:verts][j][0, 12] != s[:verts][j][0, 12] }
  s[:idx].unpack("V*").each { |x| bad += 1 if x >= s[:verts].size }
end

tot = ($smooth_edges || 0) + ($hard_edges || 0)
puts "#{File.basename(inp)}  #{m[:subs].size} sub-models, threshold #{deg.round}deg"
puts "  edges: %d rounded (%.1f%%), %d left at midpoint, %d clamped" %
     [$smooth_edges.to_i, tot.zero? ? 0 : 100.0 * $smooth_edges.to_i / tot, $hard_edges.to_i, $clamped_edges.to_i]
puts "  verts %d -> %d (x%.2f), tris %d -> %d (x%.2f)" % [bv, av, av.to_f / bv, bt, at, at.to_f / bt]
puts "  original vertices moved: #{moved} (must be 0);  bad indices: #{bad}"
abort "REFUSING: #{moved} original vertices moved" if moved > 0
abort "REFUSING: #{bad} out-of-range indices" if bad > 0

if plan
  puts "  --plan: nothing written"
else
  data = RigidModel.write(m)
  File.binwrite(out, data)
  raise "re-read failed" unless RigidModel.write(RigidModel.read(File.binread(out))) == data
  puts "  wrote #{out} (#{data.bytesize} bytes, re-read byte-identical)"
end
