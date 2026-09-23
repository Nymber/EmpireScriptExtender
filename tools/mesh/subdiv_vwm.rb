# subdiv_vwm.rb - Phase 6: actually ADD geometry to a unit, by Loop
# subdivision, producing valid influences for every new vertex.
#
# One uniform step is x4 triangles. Measured on euro_line_infantry: an
# assembled soldier goes 2,970 -> 11,880 triangles and 2,181 -> 7,347 vertices.
# (Vertices grow by the EDGE count, not x4 - these parts are open shells.)
#
# WHY LOOP AND NOT MIDPOINT
#   Midpoint (linear) subdivision costs 4x the polygons for an IDENTICAL
#   silhouette - pure expense, no quality. The quality comes from the smoothing
#   stencil, which is also what makes this non-trivial. See the seam note below.
#
# THE SEAM PROBLEM, WHICH IS THE WHOLE DIFFICULTY
#   This format stores ONE uv per vertex, so the mesh arrives already SPLIT
#   along every uv seam into duplicate vertices at the same position - 50.5% of
#   euro_line_infantry_lod1's vertices are such duplicates.
#
#   Midpoint subdivision does not care: the midpoint of the same two positions
#   is the same on both sides, so the seam stays shut. Loop subdivision very
#   much does care - its stencil reads a vertex's NEIGHBOURS, and across a
#   split each copy sees only its own side. The two sides would move apart and
#   the model would crack open along every seam.
#
#   So the topology is WELDED BY POSITION first, the stencil runs on that, and
#   the result is written back to the original split vertices - each keeping its
#   own uv. Geometry is shared; texture coordinates are not.
#
# BOUNDARY VERTICES ARE PINNED, NOT CREASED
#   These parts are open shells that abut each other (head meets body at the
#   neck, hands meet arms at the cuff): 3,452 boundary edges, zero non-manifold.
#
#   The textbook Loop boundary rule - 3/4 v + 1/8 (prev + next) - smooths ALONG
#   the border curve. That is correct for a single surface and WRONG here,
#   because two parts sharing a ring do not have the same vertex spacing along
#   it, so each side computes a different new position and the joint opens.
#   Measured, before this was changed: gaps of up to 0.049 units on a figure
#   1.98 units tall, at ten of the twelve joints - roughly 4cm on a man, at
#   exactly the range lod1 is drawn.
#
#   Counting shared vertices does NOT catch this: subdivision adds midpoints on
#   both sides at identical positions, so the shared count goes UP while the
#   original vertices drift apart. Only a distance measurement finds it.
#
#   So boundary vertices do not move at all, and boundary edges split at the
#   exact midpoint. Both are functions of the border alone, identical on both
#   sides, so every joint stays watertight by construction. The cost is that
#   border rings keep their original faceting - and those rings are inside a
#   collar, a cuff or a waistband, where nothing can see them.
#
# WHAT EACH NEW VERTEX GETS, AND ON WHAT BASIS
#   position  Loop stencil, in OBJECT space via the recovered pose, then
#             converted back into every influencing bone's frame.
#   bones     union of the edge's two endpoints. Measured max union across the
#             whole mesh: 4, so the 8-influence limit is never reached - but it
#             is enforced anyway, pruning the smallest weights and renormalising.
#   weights   mean of the endpoints, renormalised to sum to 1.
#   normal    endpoints' normals averaged in object space and renormalised, then
#             written back per bone. Original vertices KEEP their authored
#             normals; recomputing them from the new surface would change
#             shading everywhere for no requested reason.
#   uv        midpoint of the endpoints' uvs - linear along the edge, which is
#             what keeps the atlas lookup correct.
#   the two   interpolated and renormalised. These are two unit-length
#   unknown   directions (4980/4980 exactly unit length) stored ONCE per vertex.
#   floats    They are NOT bone space (that is per-influence by construction),
#             NOT object space, and NOT an orthonormal frame - |dot| between
#             them averages 0.32, and a dot product is rotation-invariant, so
#             non-orthogonality holds in every space. They correlate with the
#             uv-derived tangent/binormal at r=0.68, so they are tangent-like.
#             Their exact frame is UNKNOWN - and does not need to be known:
#             interpolating two directions and renormalising stays in whatever
#             frame they were already in.
#   tail      16 zero bytes, which is the only value this field ever takes.
#
# Usage
#   ruby subdiv_vwm.rb <in.vwm> <out.vwm> [--steps 1] [--linear] [--part NAME]

require "json"
require_relative "vwm"
require_relative "vwm_pose"
require_relative "vwm_json"

def opt(n, d = nil)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : d
end
def pname(p) = p[:name].force_encoding("UTF-16LE").encode("UTF-8")

WELD = 100_000.0     # positions within 1e-5 are the same point

# ---- one Loop step on one part ---------------------------------------------
def subdivide_part(p, pose, linear: false)
  verts = p[:verts]
  idx   = p[:idx].unpack("V*")
  n     = verts.size

  obj = verts.map { |v| to_object(pose, v[:infl][0]) }
  return nil if obj.any?(&:nil?)
  onrm = verts.map { |v| to_object_dir(pose, v[:infl][0]) }

  # --- weld by position ---
  wid = {}
  wpos = []
  vert_w = obj.map do |o|
    key = o.map { |c| (c * WELD).round }
    unless wid.key?(key)
      wid[key] = wpos.size
      wpos << o
    end
    wid[key]
  end

  # --- welded topology ---
  wfaces = idx.each_slice(3).map { |a, b, c| [vert_w[a], vert_w[b], vert_w[c]] }
  edge_faces = Hash.new { |h, k| h[k] = [] }      # welded edge -> opposite corners
  wneigh = Array.new(wpos.size) { {} }            # welded vertex -> neighbours
  wfaces.each do |a, b, c|
    [[a, b, c], [b, c, a], [c, a, b]].each do |x, y, z|
      k = x < y ? [x, y] : [y, x]
      edge_faces[k] << z
      wneigh[x][y] = true
      wneigh[y][x] = true
    end
  end
  boundary_edge = edge_faces.each_with_object({}) { |(k, v), h| h[k] = true if v.size == 1 }
  # a welded vertex is on the boundary if any of its edges is
  wbound = Array.new(wpos.size, false)
  boundary_edge.each_key { |a, b| wbound[a] = true; wbound[b] = true }

  # --- new position for each welded edge ---
  epos = {}
  edge_faces.each do |(a, b), opp|
    epos[[a, b]] =
      if linear || opp.size != 2
        scale(add(wpos[a], wpos[b]), 0.5)                       # crease / boundary
      else
        add(scale(add(wpos[a], wpos[b]), 3.0 / 8.0),
            scale(add(wpos[opp[0]], wpos[opp[1]]), 1.0 / 8.0))
      end
  end

  # --- moved position for each welded original vertex ---
  wnew = Array.new(wpos.size)
  wpos.each_index do |i|
    nb = wneigh[i].keys
    if linear || nb.empty? || wbound[i]
      # PINNED on the boundary - see the header. Moving it, even by the correct
      # Loop crease rule, opens gaps between parts that share the border.
      wnew[i] = wpos[i]
    else
      k = nb.size
      beta = (1.0 / k) * (5.0 / 8.0 - (3.0 / 8.0 + 0.25 * Math.cos(2 * Math::PI / k))**2)
      sum = nb.reduce([0.0, 0.0, 0.0]) { |acc, j| add(acc, wpos[j]) }
      wnew[i] = add(scale(wpos[i], 1.0 - k * beta), scale(sum, beta))
    end
  end

  # --- build output vertices ---
  out = []
  # originals keep every attribute; only their position moves
  verts.each_with_index do |v, i|
    nv = { head: v[:head].dup, tail: v[:tail].dup,
           infl: v[:infl].map { |f| { bone: f[:bone], mid: f[:mid].dup, weight: f[:weight] } } }
    o = wnew[vert_w[i]]
    nv[:infl].each do |f|
      f[:mid] = to_bone(pose, f[:bone], o).pack("e3") + f[:mid][12, 12]
    end
    out << nv
  end

  # one new vertex per UNWELDED edge, so the two sides of a uv seam each get
  # their own with their own uv - exactly the structure the input already has
  emid = {}
  idx.each_slice(3) do |a, b, c|
    [[a, b], [b, c], [c, a]].each do |x, y|
      k = x < y ? [x, y] : [y, x]
      next if emid.key?(k)
      emid[k] = out.size
      out << new_edge_vertex(verts[k[0]], verts[k[1]], onrm[k[0]], onrm[k[1]],
                             epos[[vert_w[k[0]], vert_w[k[1]]].minmax], pose)
    end
  end

  # --- new faces ---
  nidx = []
  idx.each_slice(3) do |a, b, c|
    ab = emid[[a, b].minmax]
    bc = emid[[b, c].minmax]
    ca = emid[[c, a].minmax]
    nidx.concat([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
  end

  { name: p[:name], vc: out.size, ic: nidx.size, verts: out, idx: nidx.pack("V*") }
end

MAX_INFL = 8

def new_edge_vertex(va, vb, na, nb, opos, pose)
  fa = va[:head].unpack("e8")
  fb = vb[:head].unpack("e8")

  uv = [(fa[0] + fb[0]) / 2.0, (fa[1] + fb[1]) / 2.0]
  # the two unknown directions: interpolate and renormalise, which is valid in
  # whatever frame they are stored in - see the header note
  d1 = unit([fa[2] + fb[2], fa[3] + fb[3], fa[4] + fb[4]]) || [fa[2], fa[3], fa[4]]
  d2 = unit([fa[5] + fb[5], fa[6] + fb[6], fa[7] + fb[7]]) || [fa[5], fa[6], fa[7]]
  head = (uv + d1 + d2).pack("e8")

  onrm = unit(add(na, nb)) || na

  w = Hash.new(0.0)
  va[:infl].each { |f| w[f[:bone]] += VWM.infl_weight(f) * 0.5 }
  vb[:infl].each { |f| w[f[:bone]] += VWM.infl_weight(f) * 0.5 }
  pairs = w.sort_by { |_, x| -x }.first(MAX_INFL)     # enforce the format's limit
  total = pairs.sum { |_, x| x }
  pairs = pairs.map { |b, x| [b, x / total] }         # renormalise after pruning

  infl = pairs.map do |bone, weight|
    { bone: bone,
      mid: to_bone(pose, bone, opos).pack("e3") + to_bone_dir(pose, bone, onrm).pack("e3"),
      weight: [weight].pack("e") }
  end
  { head: head, infl: infl, tail: "\x00" * 16 }
end

# ---- driver ----------------------------------------------------------------
src, dst = ARGV[0], ARGV[1]
abort "usage: ruby subdiv_vwm.rb <in.vwm> <out.vwm> [--steps 1] [--linear] [--part NAME]" unless dst
steps  = (opt("steps", "1")).to_i
linear = ARGV.include?("--linear")
only   = opt("part")

data = File.binread(src)
m = VWM.read(data)
abort "sanity: this file does not round-trip, refusing to modify it" unless VWM.write(m) == data

pose, _r, source = compute_pose(m)

# A FAMILY POSE THAT FITS IS NOT NECESSARILY A POSE THAT COVERS.
# compute_pose picks the family whose probe fits best, and a probe only tests
# the bones the two have in common - so a family can fit perfectly and still
# not place a bone some part of THIS mesh uses. Every horse and camel failed
# that way (70 of 72 mounts): a family fitted, then `emp_horse_A_body` or
# `stirrups_heavy_1` hit an unposed bone and the run aborted. The elephant,
# whose family happened to cover it, sailed through - which is exactly the
# shape of bug that looks like "mounts are unsupported" when it is really
# "coverage was never checked".
#
# So check coverage explicitly, and fall back to solving the pose from THIS
# mesh alone when the family comes up short. That is safe because it is not
# taken on trust: the shared-point gate below re-derives every multi-influence
# vertex and fails the run if the pose is wrong.
used = m[:parts].flat_map { |p| p[:verts].flat_map { |v| v[:infl].map { |i| i[:bone] } } }.uniq
missing = used.reject { |b| pose.key?(b) }
unless missing.empty?
  solo, resid = solve_pose_from_mesh(m)
  still = used.reject { |b| solo.key?(b) }
  if still.empty?
    warn "  #{File.basename(src)}: #{source} misses bone(s) #{missing.sort.join(',')} - " \
         "solved from this mesh instead (residual #{'%.8f' % resid})"
    pose, source = solo, "solved from this mesh alone"
  else
    abort "no pose covers bone(s) #{still.sort.join(',')} - refusing to guess"
  end
end

abort "no usable pose - cannot convert object space back to bone space" if pose.empty?
puts "#{File.basename(src)}  pose: #{pose.size} bones (#{source})#{linear ? '  [LINEAR - no smoothing]' : ''}"

before_v = m[:parts].sum { |p| p[:vc] }
before_t = m[:parts].sum { |p| p[:ic] } / 3

steps.times do |s|
  m[:parts] = m[:parts].map do |p|
    next p if only && !pname(p).downcase.include?(only.downcase)
    r = subdivide_part(p, pose, linear: linear)
    abort "part #{pname(p)} uses a bone with no pose - refusing to guess" if r.nil?
    r
  end
  puts format("  step %d: %d verts, %d tris", s + 1,
              m[:parts].sum { |p| p[:vc] }, m[:parts].sum { |p| p[:ic] } / 3)
end

# ---- the gate: is the result still validly skinned? ------------------------
worst = 0.0
checked = 0
m[:parts].each do |p|
  p[:verts].each do |v|
    next if v[:infl].size < 2
    ws = v[:infl].map { |f| to_object(pose, f) }
    next if ws.any?(&:nil?)
    checked += 1
    (1...ws.size).each { |k| d = norm(sub(ws[0], ws[k])); worst = d if d > worst }
  end
end
puts format("shared-point check: %d multi-bone vertices, worst disagreement %.8f", checked, worst)
abort "influences disagree by #{worst} - this mesh would render torn; refusing to write" if worst > 1e-3

bad_w = 0
bad_n = 0
m[:parts].each do |p|
  p[:verts].each do |v|
    bad_w += 1 if (v[:infl].sum { |f| VWM.infl_weight(f) } - 1.0).abs > 1e-3
    bad_n += 1 if v[:infl].any? { |f| (norm(VWM.infl_normal(f)) - 1.0).abs > 1e-3 }
    bad_w += 1 if v[:infl].size > MAX_INFL
  end
end
puts "weights summing to 1: #{bad_w.zero? ? 'all' : "#{bad_w} BAD"};  unit normals: #{bad_n.zero? ? 'all' : "#{bad_n} BAD"}"
abort "invalid weights or normals produced" unless bad_w.zero? && bad_n.zero?

out = VWM.write(m)
abort "the writer does not reproduce what it just wrote" unless VWM.write(VWM.read(out)) == out
File.binwrite(dst, out)

after_v = m[:parts].sum { |p| p[:vc] }
after_t = m[:parts].sum { |p| p[:ic] } / 3
puts format("verts %d -> %d (x%.2f), tris %d -> %d (x%.2f), %d -> %d bytes",
            before_v, after_v, after_v.to_f / before_v,
            before_t, after_t, after_t.to_f / before_t,
            data.bytesize, out.bytesize)
puts "written: #{dst}"
