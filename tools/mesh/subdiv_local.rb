# subdiv_local.rb - add geometry to a skinned mesh WITHOUT a global pose.
#
# WHY THIS EXISTS
#   subdiv_vwm.rb converts every vertex to object space, subdivides there, and
#   converts back - so it needs a pose for every bone the mesh touches. That is
#   fine for people. It refuses all 72 mounts, because eight thin limb bones
#   have no recoverable pose: their shared vertices are nearly collinear, so
#   any roll about the leg axis reproduces them. The pose solver is RIGHT to
#   refuse those (trap 1 in the skill - a near-zero residual does not mean a
#   correct transform, and forcing it once threw a pose 0.61 units out).
#
#   But measured across every horse lod1:
#       96.90% of edges have a bone IN COMMON at both ends
#        3.10% need a global pose
#        0.288% are genuinely blocked by an unposed bone
#   So the old tool discarded the whole mount roster over 0.3% of its geometry.
#
# THE IDEA
#   A vertex is stored once per influencing bone, in that bone's frame. If two
#   endpoints of an edge share a bone, BOTH are already expressed in that one
#   frame - no pose needed, and the arithmetic is exact rather than inferred.
#
#   Phong tessellation is built only from midpoints, dot products and
#   displacement along a normal, all equivariant under a rigid transform. So
#   running it independently in each shared bone's frame yields THE SAME WORLD
#   POINT expressed in each frame - which is exactly the shared-point invariant
#   the mesh already satisfies. Consistency is by construction, not by luck.
#
# WHAT IT DOES NOT DO
#   ORIGINAL VERTICES NEVER MOVE. Silhouette and part joints are preserved
#   exactly and no boundary pinning is needed; smoothing comes only from where
#   the new edge points are placed, as in subdiv_equip.rb.
#
#   A new vertex is skinned to the bones its endpoints SHARE, weights averaged
#   and renormalised. A bone present at only one end is dropped rather than
#   guessed - carrying it over would need the very pose this tool avoids.
#
# BLOCKED EDGES AND WHY THERE ARE NO CRACKS
#   An edge with no shared bone AND no pose covering both ends cannot be placed
#   at all, so it is not split. Leaving it split on one side would put a
#   T-junction down the seam, so triangles are emitted with TRANSITIONAL
#   patterns - 4, 3, 2 or 1 output triangles for 3, 2, 1 or 0 split edges. Both
#   triangles sharing a blocked edge see it unsplit, so the surface stays
#   watertight by construction.
#
# THE GATE HAD TO CHANGE TOO
#   subdiv_vwm.rb gates by mapping every influence to object space and checking
#   they agree. Here most multi-bone vertices touch an unposed bone, so that
#   check would silently skip exactly the geometry this tool is for. Instead
#   the gate is POSE-FREE: for a new vertex v on edge (a,b), the pairwise
#   distances among v, a and b are rigid invariants, so they must be IDENTICAL
#   measured in every shared bone frame. That tests the equivariance claim
#   directly and needs no pose at all.
#
# Usage
#   ruby subdiv_local.rb <in.vwm> <out.vwm> [--steps N] [--linear]
#   ruby subdiv_local.rb <in.vwm> --plan

require "set"
require_relative "vwm"
require_relative "vwm_json"      # compute_pose / to_object / to_bone

WELD       = 100_000.0
SMOOTH_DOT = 0.5
MAX_BULGE  = 0.15
MAX_INFL   = 8

def v_add(a, b) = [a[0]+b[0], a[1]+b[1], a[2]+b[2]]
def v_sub(a, b) = [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
def v_sc(a, s)  = [a[0]*s, a[1]*s, a[2]*s]
def v_dot(a, b) = a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
def v_len(a)    = Math.sqrt(v_dot(a, a))
def v_unit(a)   = ((l = v_len(a)) < 1e-12 ? a : v_sc(a, 1.0 / l))

$stats = Hash.new(0)
$frame_worst = 0.0        # the pose-free gate's worst disagreement

def bmap(v)
  v[:infl].to_h { |i| [i[:bone], { p: VWM.infl_pos(i), n: VWM.infl_normal(i), w: VWM.infl_weight(i) }] }
end

def phong_edge(pa, na, pb, nb, cap, linear)
  m = v_sc(v_add(pa, pb), 0.5)
  return m if linear || v_dot(na, nb) < SMOOTH_DOT
  proj = lambda do |x, p, n|
    d = v_dot(v_sub(x, p), n)
    [x[0]-d*n[0], x[1]-d*n[1], x[2]-d*n[2]]
  end
  t  = v_add(v_sc(m, 0.25), v_sc(v_sc(v_add(proj.call(m, pa, na), proj.call(m, pb, nb)), 0.5), 0.75))
  d  = v_sub(t, m)
  dl = v_len(d)
  (dl > cap && dl > 1e-12) ? v_add(m, v_sc(d, cap / dl)) : t
end

def subdivide_part(p, pose, linear: false)
  verts = p[:verts]
  idx   = p[:idx].unpack("V*")
  maps  = verts.map { |v| bmap(v) }

  # --- weld by (bone set, bone-space position). A uv seam stores one point
  # twice; across a hard edge the copies carry different normals, so average
  # them per welded position or the two sides compute different new points.
  wid = {}; wmap = []; wcount = []
  vert_w = maps.map do |bm|
    key = bm.keys.sort.map { |b| [b, bm[b][:p].map { |c| (c * WELD).round }] }
    if (j = wid[key])
      bm.each { |b, d| wmap[j][b][:n] = v_add(wmap[j][b][:n], d[:n]) }
      wcount[j] += 1
      j
    else
      wid[key] = wmap.size
      wmap << bm.to_h { |b, d| [b, { p: d[:p], n: d[:n].dup, w: d[:w] }] }
      wcount << 1
      wmap.size - 1
    end
  end

  # A WELDED NORMAL IS NOT ALWAYS MEANINGFUL, AND ASSUMING IT IS COST 8 MESHES.
  # Artillery harnesses and the elephant blanket are DOUBLE-SIDED sheets: two
  # copies at the same position with OPPOSITE normals. Summing them cancels to
  # ~0, v_unit hands back the near-zero vector, and Phong then projects along
  # garbage - which is why horse_*_artillery_lod1 and elephant_lod1 came out
  # with 70-90 non-unit normals and up to 0.026 of frame disagreement while
  # the vanilla input measured EXACTLY 0 on both counts.
  # So score each welded normal: |sum| / count is 1 when the copies agree and
  # ~0 when they cancel. Below half, there is no outward direction to speak of,
  # the vertex is marked unreliable, and any edge touching it falls back to the
  # plain midpoint - which is still frame-equivariant, so both sides of the
  # sheet stay coincident.
  wrel = []
  wmap.each_with_index do |bm, j|
    rel = bm.values.map { |d| v_len(d[:n]) / wcount[j] }.min
    wrel << (rel >= 0.5)
    bm.each_value { |d| d[:n] = v_unit(d[:n]) }
  end
  wbones = wmap.map { |bm| bm.keys.to_set }

  # --- shortest incident edge per welded vertex: the ruler for the bulge cap.
  # Lengths are rigid-invariant, so measuring in whichever frame a pair shares
  # is consistent across the mesh.
  minedge = Array.new(wmap.size, Float::INFINITY)
  seen = {}
  idx.each_slice(3) do |a, b, c|
    [[a, b], [b, c], [c, a]].each do |x, y|
      wa, wb = vert_w[x], vert_w[y]
      next if wa == wb
      k = [wa, wb].minmax
      next if seen[k]
      seen[k] = true
      sh = (wbones[wa] & wbones[wb]).min or next
      l = v_len(v_sub(wmap[wa][sh][:p], wmap[wb][sh][:p]))
      minedge[wa] = l if l < minedge[wa]
      minedge[wb] = l if l < minedge[wb]
    end
  end
  minedge.map! { |l| l.finite? ? l : 0.0 }

  out = verts.map do |v|
    { head: v[:head].dup, tail: v[:tail].dup,
      infl: v[:infl].map { |f| { bone: f[:bone], mid: f[:mid].dup, weight: f[:weight] } } }
  end

  # --- one new vertex per UNWELDED edge, so each side of a seam keeps its uv
  emid = {}
  idx.each_slice(3) do |a, b, c|
    [[a, b], [b, c], [c, a]].each do |x, y|
      k = [x, y].minmax
      next if emid.key?(k)
      nv = build_edge_vertex(verts, maps, wmap, wrel, wbones, vert_w, minedge, pose, k[0], k[1], linear)
      if nv
        emid[k] = out.size
        out << nv
      else
        emid[k] = nil
        $stats[:edge_blocked] += 1
      end
    end
  end

  # --- transitional patterns, so a blocked edge never becomes a T-junction
  nidx = []
  idx.each_slice(3) do |a, b, c|
    ab = emid[[a, b].minmax]; bc = emid[[b, c].minmax]; ca = emid[[c, a].minmax]
    n = [ab, bc, ca].count { |m| m }
    $stats["tri_#{n}"] += 1
    case n
    when 3
      nidx.concat([a, ab, ca,  b, bc, ab,  c, ca, bc,  ab, bc, ca])
    when 0
      nidx.concat([a, b, c])
    when 1
      # rotate so the one split edge is (aa,bb)
      aa, bb, cc, m = if    ab then [a, b, c, ab]
                      elsif bc then [b, c, a, bc]
                      else          [c, a, b, ca] end
      nidx.concat([aa, m, cc,  m, bb, cc])
    when 2
      # rotate so the UNSPLIT edge is (cc,aa): (aa,bb) and (bb,cc) are split
      aa, bb, cc, m1, m2 = if    ca.nil? then [a, b, c, ab, bc]
                           elsif ab.nil? then [b, c, a, bc, ca]
                           else               [c, a, b, ca, ab] end
      nidx.concat([aa, m1, cc,  m1, m2, cc,  m1, bb, m2])
    end
  end

  { name: p[:name], vc: out.size, ic: nidx.size, verts: out, idx: nidx.pack("V*") }
end

def build_edge_vertex(verts, maps, wmap, wrel, wbones, vert_w, minedge, pose, ia, ib, linear)
  wa, wb = vert_w[ia], vert_w[ib]
  shared = (wbones[wa] & wbones[wb]).to_a.sort
  cap = MAX_BULGE * [minedge[wa], minedge[wb]].min
  infl = []

  if shared.any?
    $stats[:edge_local] += 1
    bones = shared.first(MAX_INFL)
    # An unreliable welded normal means the copies cancelled - a double-sided
    # sheet. No outward direction exists, so do not pretend to smooth.
    flat = linear || !wrel[wa] || !wrel[wb]
    bones.each do |bn|
      da, db = wmap[wa][bn], wmap[wb][bn]
      pos = phong_edge(da[:p], da[:n], db[:p], db[:n], cap, flat)
      # POSITION comes from welded data so both sides of a seam agree; the
      # STORED NORMAL comes from the UNWELDED ends, exactly as the uv does, so
      # each side of a sheet keeps a real normal instead of the cancelled mean.
      ua, ub = maps[ia][bn], maps[ib][bn]
      sum = v_add(ua[:n], ub[:n])
      infl << [bn, pos, (v_len(sum) < 1e-6 ? ua[:n] : v_unit(sum)), (da[:w] + db[:w]) * 0.5]
    end
    # THE POSE-FREE GATE. |v-a|, |v-b| and |a-b| are rigid invariants, so they
    # must read the same in every shared frame. This is the direct test of the
    # equivariance the whole method rests on.
    if bones.size > 1
      ref = nil
      bones.each do |bn|
        da, db = wmap[wa][bn], wmap[wb][bn]
        pos = infl.find { |i| i[0] == bn }[1]
        trip = [v_len(v_sub(pos, da[:p])), v_len(v_sub(pos, db[:p])), v_len(v_sub(da[:p], db[:p]))]
        if ref.nil? then ref = trip
        else
          3.times { |k| d = (trip[k] - ref[k]).abs; $frame_worst = d if d > $frame_worst }
        end
      end
    end
  else
    both = (wbones[wa] | wbones[wb]).to_a.sort
    return nil unless both.all? { |bn| pose.key?(bn) }     # BLOCKED - do not split
    $stats[:edge_pose] += 1
    oa = to_object(pose, verts[ia][:infl][0])
    ob = to_object(pose, verts[ib][:infl][0])
    return nil if oa.nil? || ob.nil?
    om = v_sc(v_add(oa, ob), 0.5)
    on = v_unit(v_add(to_object_dir(pose, verts[ia][:infl][0]), to_object_dir(pose, verts[ib][:infl][0])))
    both.first(MAX_INFL).each do |bn|
      src = wmap[wa][bn] || wmap[wb][bn]
      infl << [bn, to_bone(pose, bn, om), to_bone_dir(pose, bn, on), src[:w] * 0.5]
    end
  end

  tw = infl.sum { |i| i[3] }
  return nil if tw <= 0
  infl.each { |i| i[3] /= tw }

  fa = verts[ia][:head].unpack("e8")
  fb = verts[ib][:head].unpack("e8")
  head = Array.new(8)
  head[0] = (fa[0] + fb[0]) * 0.5
  head[1] = (fa[1] + fb[1]) * 0.5
  [2, 5].each { |o| head[o, 3] = v_unit(v_sc(v_add(fa[o, 3], fb[o, 3]), 0.5)) }

  { head: head.pack("e8"), tail: verts[ia][:tail].dup,
    infl: infl.map { |bn, pos, nrm, w|
      { bone: bn, mid: pos.pack("e3") + nrm.pack("e3"), weight: [w].pack("e") } } }
end

# ---- driver ----------------------------------------------------------------
src, dst = ARGV[0], ARGV[1]
plan = ARGV.include?("--plan")
abort "usage: subdiv_local.rb <in.vwm> <out.vwm> [--steps N] [--linear] | <in.vwm> --plan" unless src && (dst || plan)
i = ARGV.index("--steps"); steps = i ? ARGV[i + 1].to_i : 1
linear = ARGV.include?("--linear")

data = File.binread(src)
m = VWM.read(data)
abort "sanity: this file does not round-trip, refusing to modify it" unless VWM.write(m) == data
pose, _r, source = compute_pose(m)

before_v = m[:parts].sum { |p| p[:vc] }
before_t = m[:parts].sum { |p| p[:ic] } / 3
steps.times { m[:parts] = m[:parts].map { |p| subdivide_part(p, pose, linear: linear) } }
after_v = m[:parts].sum { |p| p[:vc] }
after_t = m[:parts].sum { |p| p[:ic] } / 3

# secondary gate, where a pose happens to exist
worst = 0.0; checked = 0; ungated = 0
bad_w = 0; bad_n = 0; over = 0
m[:parts].each do |p|
  p[:verts].each do |v|
    bad_w += 1 if (v[:infl].sum { |f| VWM.infl_weight(f) } - 1.0).abs > 1e-3
    v[:infl].each { |f| bad_n += 1 if (v_len(VWM.infl_normal(f)) - 1.0).abs > 1e-3 }
    over += 1 if v[:infl].size > MAX_INFL
    next if v[:infl].size < 2
    pts = v[:infl].map { |f| to_object(pose, f) }
    if pts.any?(&:nil?) then ungated += 1; next end
    checked += 1
    pts.combination(2) { |x, y| d = v_len(v_sub(x, y)); worst = d if d > worst }
  end
end
maxidx = m[:parts].map { |p| p[:idx].unpack("V*").max.to_i }.max
badidx = m[:parts].sum { |p| p[:idx].unpack("V*").count { |x| x >= p[:vc] } }

puts "#{File.basename(src)}  pose: #{pose.size} bones (#{source})"
puts "  edges: #{$stats[:edge_local]} shared-frame, #{$stats[:edge_pose]} via pose, #{$stats[:edge_blocked]} blocked"
puts "  triangles by splits: 3->#{$stats['tri_3']} 2->#{$stats['tri_2']} 1->#{$stats['tri_1']} 0->#{$stats['tri_0']}"
puts "  POSE-FREE frame agreement : #{'%.9f' % $frame_worst}"
puts "  pose-based shared-point   : #{checked} checked, worst #{'%.8f' % worst}#{ungated.zero? ? '' : " (#{ungated} touch an unposed bone)"}"
puts "  weights off 1.0: #{bad_w};  non-unit normals: #{bad_n};  over-budget: #{over};  bad indices: #{badidx}"
puts format("  verts %d -> %d (x%.2f), tris %d -> %d (x%.2f)",
            before_v, after_v, after_v.to_f / before_v, before_t, after_t, after_t.to_f / before_t)

abort "REFUSING: frame disagreement #{$frame_worst}" if $frame_worst > 1e-5
abort "REFUSING: shared-point disagreement #{worst}" if worst > 1e-3
abort "REFUSING: #{bad_w} vertices whose weights do not sum to 1" if bad_w > 0
abort "REFUSING: #{badidx} out-of-range indices" if badidx > 0
abort "REFUSING: #{over} vertices over the influence budget" if over > 0

unless plan
  out = VWM.write(m)
  File.binwrite(dst, out)
  raise "re-read failed" unless VWM.write(VWM.read(File.binread(dst))) == out
  puts "  written: #{dst} (#{out.bytesize} bytes, re-read byte-identical)"
end
