# subdiv_prop_lib.rb - Phong tessellation for RIGID 20-float geometry.
#
# Shared by subdiv_equip.rb (weapons and worn kit, inside euro_equipment) and
# subdiv_rigid.rb (buildings, forts, props, in .rigid_model). Both containers
# hold the SAME vertex - 20 flat floats, no influence blocks - so they get one
# implementation. Duplicating it is how two tools quietly diverge.
#
# SMOOTH_DOT and MAX_BULGE are deliberately NOT constants here: the right
# threshold differs by content. Weapons want 0.5 (60 deg) because a musket is
# mostly smooth revolved surfaces. ARCHITECTURE WANTS ~0.866 (30 deg) - at 60
# deg, 14.5% of building edges measured as 45-60 deg "soft corners" that are
# really window reveals and buttress edges, and rounding those makes masonry
# look melted. Pass the value in.
#
# Everything else carries over from the weapons work, including the two
# guards that cost real measurements to find - see subdiv_equip.rb's header
# for why MAX_BULGE is scaled to the SHORTEST INCIDENT EDGE rather than to
# the edge's own length.

WELD = 100_000.0     # positions within 1e-5 are the same point
SMOOTH_DOT = 0.5     # cos 60deg: past this an edge is a crease, not a smooth surface
MAX_BULGE  = 0.15    # cap the Phong displacement at this fraction of the edge length

# What a European line infantryman actually carries and shows. Everything else
# is left vanilla on purpose - see the no-LOD note above.
DEFAULT_ONLY = /musket0|rifle0|carbine01|bayonet01|backpack0|_bag0|flask0|hanger0|drum01|drumstick|cartridge/

def add(a, b)   = [a[0]+b[0], a[1]+b[1], a[2]+b[2]]
def scale(a, s) = [a[0]*s, a[1]*s, a[2]*s]
def unit(a)
  l = Math.sqrt(a[0]**2 + a[1]**2 + a[2]**2)
  l < 1e-12 ? a : [a[0]/l, a[1]/l, a[2]/l]
end

def subdivide_sub(s, linear: false, smooth_dot: SMOOTH_DOT, max_bulge: MAX_BULGE)
  fs  = s[:verts].map { |v| v.unpack("e20") }
  idx = s[:idx].unpack("V*")

  # --- weld by position: a uv seam stores the same point twice ---
  # Welding matters even though originals never move: both copies of a seam
  # edge must compute the SAME new midpoint, and across a hard edge the two
  # copies carry different normals. Averaging per welded position makes the
  # projection single-valued, so seams stay shut by construction.
  wid = {}; wpos = []; wnrm = []
  vert_w = fs.map do |f|
    key = f[0, 3].map { |c| (c * WELD).round }
    if (j = wid[key])
      wnrm[j] = add(wnrm[j], f[3, 3])
      j
    else
      wid[key] = wpos.size
      wpos << f[0, 3]
      wnrm << f[3, 3]
      wpos.size - 1
    end
  end
  wnrm.map! { |n| unit(n) }

  edge_faces = Hash.new { |h, k| h[k] = [] }
  idx.each_slice(3) do |ia, ib, ic|
    a, b, c = vert_w[ia], vert_w[ib], vert_w[ic]
    [[a, b, c], [b, c, a], [c, a, b]].each do |x, y, z|
      edge_faces[x < y ? [x, y] : [y, x]] << z
    end
  end

  # --- PHONG TESSELLATION, not Loop ---------------------------------------
  # Loop converges to a surface INSCRIBED in the control mesh. On a torso that
  # is invisible; on a gun barrel whose cross-section is a 6-8 sided polygon it
  # eats the radius - measured, before this was changed: musket barrel -20%,
  # socket bayonet -28% thickness and -9.4% length. Skinny muskets are worse
  # than vanilla, not better.
  #
  # Phong tessellation instead projects the edge midpoint onto the tangent
  # plane at each endpoint and blends. The normals already encode "this is a
  # cylinder", so the midpoint lands back out ON the implied surface and the
  # radius is preserved. Two further properties matter here: ORIGINAL VERTICES
  # NEVER MOVE (so the silhouette and every part joint are exact by
  # construction, with no boundary pinning needed), and the new position
  # depends only on the two endpoints, so it is identical from either side of
  # a seam.
  #
  # ALPHA is the standard Phong shape factor. 1.0 projects fully onto the
  # tangent planes and overshoots on tight curvature; 0.75 is the usual
  # compromise and is what the measured numbers below were taken with.
  #
  # TWO GUARDS, BOTH PAID FOR IN MEASUREMENTS
  #
  # Unguarded Phong overshot far worse than Loop undershot: musket barrel
  # +207% on one axis, east_rdrumstick +466%. The cause is these props being
  # low-poly HARD-SURFACE objects. Welding averages the normals of every facet
  # meeting at a position, and across a crease that average points nearly
  # ALONG the facet rather than out of it - so (m-p).n is large and the
  # projection flies away. Phong assumes a smooth surface; a musket butt-plate
  # is not one.
  #
  #   SMOOTH_DOT - if the two endpoint normals disagree by more than 60 deg
  #     the edge is a crease or a cap, there is no smooth surface to recover,
  #     and the plain midpoint is the honest answer.
  #   MAX_BULGE  - even on a smooth edge, cap the displacement at a fraction
  #     of the edge length. A correct ring of a hexagonal barrel needs about
  #     0.134 x radius; anything past 0.15 x edge is the guard catching a case
  #     the dot product let through.
  alpha = linear ? 0.0 : 0.75
  proj = lambda do |x, p, n|
    d = (x[0]-p[0])*n[0] + (x[1]-p[1])*n[1] + (x[2]-p[2])*n[2]
    [x[0]-d*n[0], x[1]-d*n[1], x[2]-d*n[2]]
  end
  # shortest edge meeting each welded vertex - the ruler for the bulge cap
  minedge = Array.new(wpos.size, Float::INFINITY)
  edge_faces.each_key do |(a, b)|
    l = Math.sqrt((wpos[a][0]-wpos[b][0])**2 + (wpos[a][1]-wpos[b][1])**2 +
                  (wpos[a][2]-wpos[b][2])**2)
    minedge[a] = l if l < minedge[a]
    minedge[b] = l if l < minedge[b]
  end

  $smooth_edges ||= 0; $hard_edges ||= 0; $clamped_edges ||= 0
  epos = {}
  edge_faces.each_key do |(a, b)|
    m = scale(add(wpos[a], wpos[b]), 0.5)
    na, nb = wnrm[a], wnrm[b]
    dot = na[0]*nb[0] + na[1]*nb[1] + na[2]*nb[2]
    if alpha.zero? || dot < smooth_dot
      $hard_edges += 1
      epos[[a, b]] = m
      next
    end
    $smooth_edges += 1
    pa = proj.call(m, wpos[a], na)
    pb = proj.call(m, wpos[b], nb)
    t  = add(scale(m, 1.0 - alpha), scale(scale(add(pa, pb), 0.5), alpha))
    d  = [t[0]-m[0], t[1]-m[1], t[2]-m[2]]
    dl = Math.sqrt(d[0]**2 + d[1]**2 + d[2]**2)
    # SCALE THE CAP TO LOCAL FEATURE SIZE, NOT TO THIS EDGE'S LENGTH.
    # A musket is 1.70 long and 0.067 thick. Capping at 0.15 x edge length let
    # a lengthwise edge bulge by 0.15 x 0.8 = 0.12 - 1.8x the entire thickness
    # of the gun, which balloons the barrel. Measured: 27 of 50 sub-models blew
    # up that way, all of them thin and elongated, while chunky ones (drums,
    # flasks, packs) stayed at 0.04-0.08x.
    # The shortest edge meeting either endpoint tracks the thin direction, so
    # it is the right ruler. On a hexagonal barrel the cross-section edges are
    # ~0.03 and correct cylinder rounding needs ~0.134 x radius = 0.0045 -
    # which is what 0.15 x 0.03 allows. The cap bites exactly where the
    # geometry is thin and gets out of the way where it is not.
    cap = max_bulge * [minedge[a], minedge[b]].min
    if dl > cap && dl > 1e-12
      $clamped_edges += 1
      t = add(m, scale(d, cap / dl))
    end
    epos[[a, b]] = t
  end

  # --- originals are copied through UNCHANGED, attributes and all ---
  out = fs.map(&:dup)

  # --- one new vertex per UNWELDED edge, so each side of a seam keeps its uv ---
  emid = {}
  idx.each_slice(3) do |a, b, c|
    [[a,b],[b,c],[c,a]].each do |x, y|
      k = x < y ? [x, y] : [y, x]
      next if emid.key?(k)
      emid[k] = out.size
      fa = fs[k[0]]; fb = fs[k[1]]
      g = Array.new(20)
      g[0, 3]  = epos[[vert_w[k[0]], vert_w[k[1]]].minmax]
      g[3, 3]  = unit(scale(add(fa[3, 3],  fb[3, 3]),  0.5))
      g[6, 2]  = [(fa[6]+fb[6])*0.5, (fa[7]+fb[7])*0.5]
      g[8, 3]  = unit(scale(add(fa[8, 3],  fb[8, 3]),  0.5))
      g[11, 3] = unit(scale(add(fa[11,3],  fb[11,3]),  0.5))
      g[14, 6] = fa[14, 6]          # colour + the two per-sub-model constants
      out << g
    end
  end

  nidx = []
  idx.each_slice(3) do |a, b, c|
    ab = emid[[a,b].minmax]; bc = emid[[b,c].minmax]; ca = emid[[c,a].minmax]
    nidx.concat([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
  end

  s.merge(verts: out.map { |g| g.pack("e20") }, idx: nidx.pack("V*"))
end
