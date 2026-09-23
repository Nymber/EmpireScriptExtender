# subdiv_plan.rb - what would it actually COST to subdivide a unit, and what
# breaks first? Phase 6 planning, done on real topology rather than the
# "one subdivision = 4x triangles" rule of thumb.
#
# WHY MEASURE INSTEAD OF ASSUMING
#   Triangles do go up 4x per step. VERTICES do not - they go up by the EDGE
#   count, which depends on how open the surface is, and Empire's parts are
#   not closed shells. The vertex count is what drives file size, skinning
#   cost and the influence budget, so it is the number worth having.
#
# WHAT THIS CHECKS.
#
#   1. INFLUENCE BUDGET. A vertex inserted on an edge inherits the union of
#      its two endpoints' bones. The format allows at most 8 influences
#      (measured: the corpus uses up to 8). An edge spanning two richly
#      weighted vertices can exceed that, and the extra weights have to be
#      dropped and renormalised - which moves the vertex. This counts how
#      often it would happen before any code is written.
#
#   2. UV SEAMS. This format stores ONE uv per vertex, so the mesh is already
#      SPLIT along every uv seam into duplicate vertices at the same position.
#      That is fine for linear (midpoint) subdivision - the midpoint of the
#      same two positions is the same on both sides, so the seam stays shut.
#      It is NOT fine for smoothed (Loop) subdivision, whose stencil uses
#      neighbours, which differ across the split: the two sides move apart and
#      the model cracks open along every seam. This reports how much of the
#      mesh is seam, i.e. how much work seam-aware smoothing is.
#
#   3. NON-MANIFOLD / BOUNDARY EDGES. Edges used by one triangle are open
#      boundaries; edges used by three or more are non-manifold and have no
#      well-defined smoothing stencil at all.
#
# Usage
#   ruby subdiv_plan.rb <mesh.vwm> [--target 5.0]

require "json"
require_relative "vwm"
require_relative "vwm_pose"
require_relative "vwm_json"

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end

path = ARGV[0]
abort "usage: ruby subdiv_plan.rb <mesh.vwm> [--target 5.0]" unless path && File.file?(path)
target = opt("target", "5.0").to_f

m = VWM.read(File.binread(path))
pose, _r, source = compute_pose(m)
puts "#{File.basename(path)}   pose: #{pose.size} bones (#{source})"

def pname(p) = p[:name].force_encoding("UTF-16LE").encode("UTF-8")

# edges, with how many triangles use each
def edges_of(part)
  use = Hash.new(0)
  idx = part[:idx].unpack("V*")
  idx.each_slice(3) do |a, b, c|
    [[a, b], [b, c], [c, a]].each { |x, y| use[x < y ? [x, y] : [y, x]] += 1 }
  end
  use
end

rows = []
tot_v = tot_f = 0
m[:parts].each do |p|
  use = edges_of(p)
  e = use.size
  f = p[:ic] / 3
  v = p[:vc]
  tot_v += v
  tot_f += f

  boundary = use.count { |_, n| n == 1 }
  nonman   = use.count { |_, n| n > 2 }

  # influence union across each edge
  bones = p[:verts].map { |x| x[:infl].map { |i| i[:bone] } }
  over8 = use.keys.count { |a, b| (bones[a] | bones[b]).size > 8 }
  maxu  = use.keys.map { |a, b| (bones[a] | bones[b]).size }.max || 0

  # duplicate positions = uv seam splits
  pos = Hash.new(0)
  p[:verts].each do |x|
    o = to_object(pose, x[:infl][0]) or next
    pos[o.map { |c| (c * 100_000).round }] += 1
  end
  dup = pos.values.select { |c| c > 1 }.sum

  rows << { name: pname(p), v: v, f: f, e: e, boundary: boundary, nonman: nonman,
            over8: over8, maxu: maxu, dup: dup }
end

puts
puts format("  %-36s %6s %6s %6s | %8s %8s | %s", "part", "verts", "tris", "edges", "1x verts", "1x tris", "seam/bnd/>8")
rows.each do |r|
  puts format("  %-36s %6d %6d %6d | %8d %8d | %4d %4d %4d%s",
              r[:name], r[:v], r[:f], r[:e], r[:v] + r[:e], r[:f] * 4,
              r[:dup], r[:boundary], r[:over8], r[:nonman].zero? ? "" : "  NON-MANIFOLD #{r[:nonman]}")
end

tot_e = rows.sum { |r| r[:e] }
puts
puts format("whole file : %d verts, %d tris, %d edges", tot_v, tot_f, tot_e)
puts format("  1 subdivision : %d verts (x%.2f), %d tris (x4)", tot_v + tot_e, (tot_v + tot_e).to_f / tot_v, tot_f * 4)
# second step: each edge splits in two, each face contributes three interior edges
e2 = 2 * tot_e + 3 * tot_f
v2 = (tot_v + tot_e) + e2
puts format("  2 subdivisions: %d verts (x%.2f), %d tris (x16)", v2, v2.to_f / tot_v, tot_f * 16)

puts
puts "TOTALS THAT MATTER - one ASSEMBLED soldier, not the variant library"
# a soldier picks one of each variant group; group by the trailing NN
groups = rows.group_by { |r| r[:name].sub(/\d+$/, "") }
pick = groups.map { |_, g| g.max_by { |r| r[:f] } }
sv = pick.sum { |r| r[:v] }
sf = pick.sum { |r| r[:f] }
se = pick.sum { |r| r[:e] }
puts "  parts: #{pick.map { |r| r[:name] }.join(', ')}"
puts format("  now            : %5d verts %5d tris", sv, sf)
puts format("  1 subdivision  : %5d verts %5d tris   (x%.1f tris)", sv + se, sf * 4, 4.0)
e2s = 2 * se + 3 * sf
puts format("  2 subdivisions : %5d verts %5d tris   (x%.1f tris)", (sv + se) + e2s, sf * 16, 16.0)

puts
puts format("TARGET x%.1f", target)
# one global step is x4; buy the rest by subdividing the parts that read most
budget = (sf * target).round
puts format("  budget: %d tris for the assembled soldier (now %d)", budget, sf)
after1 = sf * 4
extra = budget - after1
puts format("  after one global step: %d tris, %+d to spend", after1, extra)
if extra > 0
  cand = pick.sort_by { |r| -r[:f] }
  spent = 0
  chosen = []
  cand.each do |r|
    cost = r[:f] * 4 * 3          # a second step on this part: 4F -> 16F, i.e. +12F... but it is already 4F, so +3 * 4F
    next if spent + cost > extra
    chosen << r[:name]
    spent += cost
  end
  puts format("  a second step on: %s", chosen.empty? ? "(nothing fits)" : chosen.join(", "))
  puts format("  final: %d tris (x%.2f)", after1 + spent, (after1 + spent).to_f / sf)
end

puts
puts "RISKS FOUND"
o8 = rows.sum { |r| r[:over8] }
puts "  edges whose endpoint bones union to MORE than 8 influences: #{o8}" \
     "#{o8.zero? ? '   none - the influence budget is not a problem' : '   <-- these need weight pruning'}"
puts "  max union seen on any edge: #{rows.map { |r| r[:maxu] }.max}"
dups = rows.sum { |r| r[:dup] }
puts format("  vertices duplicated at a shared position (uv seams): %d of %d (%.1f%%)",
            dups, tot_v, dups * 100.0 / tot_v)
puts "     -> linear subdivision keeps these shut; SMOOTHED subdivision must be seam-aware"
nm = rows.sum { |r| r[:nonman] }
puts "  non-manifold edges: #{nm}#{nm.zero? ? '   clean' : '   <-- no smoothing stencil here'}"
bnd = rows.sum { |r| r[:boundary] }
puts "  boundary (open) edges: #{bnd}"
