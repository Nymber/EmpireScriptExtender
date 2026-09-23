# vwm_pose.rb - recover the skeleton POSE from a mesh, so bone-space geometry
# can be converted to object space and back.
#
# Phase 4b of ROADMAP_HIGH_POLY_UNITS.md - the last technical gap before an
# artist can model a unit.
#
# THE INSIGHT
#   Empire stores each vertex ONCE PER INFLUENCING BONE, in that bone's space.
#   Every one of those copies is the SAME world point. So for two bones A and B
#   and the vertices they share, {p_a} and {p_b} are related by a RIGID
#   transform - and that transform is exactly the relative pose of the bones.
#
#   Verified before building anything: across every bone pair of every part,
#   pairwise distances agree to 0.000000. The data is EXACT, not noisy.
#
#   So the pose comes out of the MESH. The .anim format does not need to be
#   decoded for this, which matters because its community parser splits fields
#   by byte count rather than meaning (a near-constant 0.483 repeated across
#   unrelated bones gives that away).
#
# WHY NO SVD / KABSCH
#   Those exist to fit a transform to NOISY correspondences. These are exact,
#   so three well-spread points determine the answer outright: build an
#   orthonormal frame from each triple and the rotation is Fa * Fb^T. The
#   result is then CHECKED against every shared vertex - if the residual is
#   not ~0 the assumption was wrong and the tool says so rather than returning
#   a plausible matrix.
#
# Usage
#   ruby vwm_pose.rb <mesh.vwm> [--skeleton skeleton.json] [--check]

require "json"
require_relative "vwm"

def sub(a, b) = [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
def add(a, b) = [a[0]+b[0], a[1]+b[1], a[2]+b[2]]
def dot(a, b) = a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
def cross(a, b) = [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def norm(a) = Math.sqrt(dot(a, a))
def scale(a, s) = [a[0]*s, a[1]*s, a[2]*s]
def unit(a) = (n = norm(a)) < 1e-12 ? nil : scale(a, 1.0 / n)

# rotation as a 3x3, row-major
def mat_mul_vec(m, v)
  [m[0]*v[0]+m[1]*v[1]+m[2]*v[2],
   m[3]*v[0]+m[4]*v[1]+m[5]*v[2],
   m[6]*v[0]+m[7]*v[1]+m[8]*v[2]]
end
def mat_mul(a, b)
  r = Array.new(9, 0.0)
  3.times { |i| 3.times { |j| 3.times { |k| r[i*3+j] += a[i*3+k] * b[k*3+j] } } }
  r
end
def mat_t(m) = [m[0],m[3],m[6], m[1],m[4],m[7], m[2],m[5],m[8]]
IDENT = [1.0,0,0, 0,1.0,0, 0,0,1.0]

# Orthonormal frame from three points; nil if they are collinear.
def frame(p1, p2, p3)
  e1 = unit(sub(p2, p1)) or return nil
  v  = sub(p3, p1)
  e2 = unit(sub(v, scale(e1, dot(v, e1)))) or return nil
  e3 = cross(e1, e2)
  [e1[0], e2[0], e3[0],
   e1[1], e2[1], e3[1],
   e1[2], e2[2], e3[2]]          # columns are the basis vectors
end

# Rigid transform taking b-space points to a-space: p_a = R * p_b + t
def solve_rigid(pts)
  return nil if pts.size < 3
  # pick the triple with the largest triangle area - most numerically stable,
  # and collinear triples give no rotation about their own axis
  best = nil; best_area = 0.0
  n = [pts.size, 24].min
  (0...n).each do |i|
    ((i+1)...n).each do |j|
      ((j+1)...n).each do |k|
        a = norm(cross(sub(pts[j][0], pts[i][0]), sub(pts[k][0], pts[i][0])))
        if a > best_area then best_area = a; best = [i, j, k] end
      end
    end
  end
  return nil if best.nil? || best_area < 1e-9
  i, j, k = best
  fa = frame(pts[i][0], pts[j][0], pts[k][0]) or return nil
  fb = frame(pts[i][1], pts[j][1], pts[k][1]) or return nil
  r  = mat_mul(fa, mat_t(fb))
  t  = sub(pts[i][0], mat_mul_vec(r, pts[i][1]))
  # residual over EVERY correspondence, not just the three used
  err = pts.map { |pa, pb| norm(sub(pa, add(mat_mul_vec(r, pb), t))) }.max

  # CONFIDENCE, and why a near-zero residual is not enough on its own.
  #   Three points determine a rotation exactly - in exact arithmetic. These
  #   are float32, so the rotation's accuracy scales with how SPREAD OUT the
  #   triple is. A finger bone shares five almost-collinear vertices with its
  #   neighbour: any roll about the finger's axis fits those five points to
  #   ~0, so `err` says EXACT while the roll is essentially unconstrained.
  #   Composing a chain through such a bone then throws the far end a long way
  #   off - which is exactly how the pooled human pose went wrong by 0.61
  #   units while every pair reported a 4.6e-7 residual.
  #
  #   Triangle area normalised by the cloud's own size is the honest measure:
  #   it is scale-free, it is near zero precisely when the points are
  #   collinear, and coplanar-but-spread points (which ARE well determined)
  #   score high, as they should.
  span = 0.0
  n.times { |a| ((a + 1)...n).each { |b| d = norm(sub(pts[a][0], pts[b][0])); span = d if d > span } }
  conf = span < 1e-9 ? 0.0 : best_area / (span * span)
  { r: r, t: t, err: err, n: pts.size, conf: conf, span: span }
end

# ---- gather correspondences ------------------------------------------------
def bone_pairs(m)
  pairs = Hash.new { |h, k| h[k] = [] }
  m[:parts].each do |p|
    p[:verts].each do |v|
      next if v[:infl].size < 2
      v[:infl].combination(2) do |x, y|
        a, b = x[:bone] < y[:bone] ? [x, y] : [y, x]
        pairs[[a[:bone], b[:bone]]] << [VWM.infl_pos(a), VWM.infl_pos(b)]
      end
    end
  end
  pairs
end

# ---- compose into world transforms ----------------------------------------
# Relative transforms form a graph over bones; walk it from a root so every
# bone gets a transform in one common space.
# The relative transforms form a GRAPH over bones with more edges than a tree
# needs, so which edges get used decides the answer. Edges are not equally
# trustworthy (see `conf` in solve_rigid), and error COMPOUNDS along a chain -
# so this grows a MAXIMUM SPANNING TREE by confidence, which is also the
# maximum-bottleneck tree: every bone is reached by the path whose weakest link
# is as strong as possible.
#
# Taking edges in hash order instead - the obvious thing, and what this did
# first - routes the hand through a finger joint and throws bones 0.6 units out
# of place while every individual edge still reports an exact residual.
#
# `seed:` EXTENDS an existing pose instead of starting from a bare root. That
# is how a pose grows to cover bones no single mesh could place: bones already
# placed keep their transforms exactly, and only new ones are added, relative
# to them. Because nothing already placed ever moves, a mesh that fitted the
# pose before still fits it after - which is what makes incremental family
# building stable instead of oscillating.
def build_pose(rel, bones_seen, root: nil, seed: nil)
  if seed && !seed.empty?
    pose = seed.dup
  else
    root ||= bones_seen.include?(0) ? 0 : bones_seen.min
    pose = { root => { r: IDENT, t: [0.0, 0.0, 0.0] } }
  end
  adj = Hash.new { |h, k| h[k] = [] }
  rel.each do |(a, b), tr|
    adj[a] << [b, tr, false]     # false: apply tr as given
    adj[b] << [a, tr, true]      # true:  apply its inverse
  end

  frontier = pose.keys.flat_map do |b|
    adj[b].map { |to, tr, inv| [tr[:conf] || 1.0, b, to, tr, inv] }
  end
  until frontier.empty?
    best_i = (0...frontier.size).max_by { |i| frontier[i][0] }
    _c, from, to, tr, inv = frontier.delete_at(best_i)
    next if pose[to]
    pf = pose[from]
    pose[to] =
      if inv
        # edge stores p_from = R*p_to + t, so going from->to needs the inverse
        rt = mat_t(tr[:r])
        ti = scale(mat_mul_vec(rt, tr[:t]), -1.0)
        { r: mat_mul(pf[:r], rt), t: add(mat_mul_vec(pf[:r], ti), pf[:t]) }
      else
        { r: mat_mul(pf[:r], tr[:r]), t: add(mat_mul_vec(pf[:r], tr[:t]), pf[:t]) }
      end
    adj[to].each do |n2, tr2, inv2|
      frontier << [tr2[:conf] || 1.0, to, n2, tr2, inv2] unless pose[n2]
    end
  end
  pose
end

# ---- driver ----------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
mesh = ARGV[0]
abort "usage: ruby vwm_pose.rb <mesh.vwm> [--skeleton s.json] [--check]" unless mesh && File.file?(mesh)
skel_path = (i = ARGV.index("--skeleton")) ? ARGV[i + 1] : nil
names = skel_path && File.file?(skel_path) ? JSON.parse(File.read(skel_path))["bones"].map(&:first) : nil

m = VWM.read(File.binread(mesh))
pairs = bone_pairs(m)
rel = {}
worst = 0.0
pairs.each do |key, pts|
  s = solve_rigid(pts)
  next unless s
  rel[key] = s
  worst = s[:err] if s[:err] > worst
end

seen = rel.keys.flatten.uniq.sort
pose = build_pose(rel, seen)

puts "bone pairs solved : #{rel.size}"
puts "worst residual    : #{format('%.8f', worst)}#{worst < 1e-5 ? '   EXACT' : '   <-- NOT rigid, assumption is wrong'}"
puts "bones placed      : #{pose.size} of #{seen.size} seen"
unplaced = seen - pose.keys
puts "unplaced bones    : #{unplaced.inspect}" unless unplaced.empty?

if ARGV.include?("--check")
  # Every influence of a vertex must map to the SAME world point. That is the
  # property the whole conversion rests on, so check it directly.
  bad = 0; tested = 0; maxd = 0.0
  m[:parts].each do |p|
    p[:verts].each do |v|
      next if v[:infl].size < 2
      ws = v[:infl].map do |i|
        po = pose[i[:bone]] or next nil
        add(mat_mul_vec(po[:r], VWM.infl_pos(i)), po[:t])
      end
      next if ws.any?(&:nil?)
      tested += 1
      d = norm(sub(ws[0], ws[1]))
      maxd = d if d > maxd
      bad += 1 if d > 1e-4
    end
  end
  puts "\nmulti-influence vertices checked: #{tested}"
  puts "max disagreement between influences: #{format('%.8f', maxd)}"
  puts bad.zero? ? "ALL influences agree - the pose is correct" : "#{bad} vertices disagree"

  ys = []
  m[:parts].each do |p|
    p[:verts].each do |v|
      po = pose[v[:infl][0][:bone]] or next
      ys << add(mat_mul_vec(po[:r], VWM.infl_pos(v[:infl][0])), po[:t])
    end
  end
  unless ys.empty?
    puts "\nassembled figure extent (object space):"
    3.times do |c|
      vals = ys.map { |q| q[c] }
      puts format("  axis %d: %.3f .. %.3f   (span %.3f)", c, vals.min, vals.max, vals.max - vals.min)
    end
  end
end

if names
  puts "\nplaced bones:"
  pose.keys.sort.first(12).each { |b| puts format("  %2d %s", b, names[b] || "?") }
end
end
