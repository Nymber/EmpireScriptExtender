# vwm_pose_global.rb - solve the reference pose for each SKELETON FAMILY in
# the mesh corpus, by pooling evidence across every mesh that shares a skeleton.
#
# Phase 4b of ROADMAP_HIGH_POLY_UNITS.md, second half.
#
# WHY POOLING IS NEEDED
#   `vwm_pose.rb` recovers the pose from a single mesh. That works, but has two
#   flaws that only appear once you try to use it:
#
#   1. COVERAGE. A bone is locatable only if it shares a vertex with another
#      bone. `euro_line_infantry_lod1` leaves bone 23 (Eyes) unplaced - its
#      vertices are all single-influence - so 16 vertices get no object-space
#      position. Lower LODs are worse: lod3 places 32 of the 35 bones it uses,
#      because simplification removes exactly the blended vertices.
#   2. DRIFT. Solved separately, each mesh gets a slightly different pose
#      (~1e-6). All four LODs of a unit ship together, so they would disagree
#      about where the bones are.
#
#   Both vanish if meshes on the same skeleton are solved together. And they
#   CAN be: relative transforms solved independently from `euro_line_infantry`
#   and `african_slaver_musketeers` agree to 1.4e-6 in rotation and 2.9e-7 in
#   translation, and lod1 vs lod3 likewise.
#
# WHY "FAMILY" AND NOT ONE GLOBAL POSE
#   Pooling the WHOLE corpus produces nonsense - worst residual 0.63, every
#   mesh disagreeing with itself by up to 2.4 units. The reason is that the
#   corpus is not one skeleton: `campaign_*` map models, horses and crews have
#   their own rigs, and bone 19 does not mean the same thing in each. Bone
#   indices are only comparable within a rig.
#
#   So the meshes are CLUSTERED first, by whether their independently solved
#   bone-to-bone transforms actually agree. That needs no skeleton metadata and
#   no guesswork: two meshes are in the same family iff the transforms they
#   both observe match. A mesh that matches nothing gets its own family and is
#   reported rather than forced into one.
#
# WHAT THIS IS NOT
#   Not the .anim bind pose. It is the pose the MESH data is expressed in,
#   which is the only one that matters for converting bone space to object
#   space and back, and it is checked against every mesh it was derived from.
#
# Usage
#   ruby vwm_pose_global.rb [--game DIR] [--out docs/warscape_pose.json]
#                           [--limit N] [--verbose]

require "json"
require_relative "vwm"
require_relative "vwm_pose"

require_relative "../../empire_paths"

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
GAME    = opt("game", EMPIRE.game)
OUT     = opt("out", File.expand_path("../../docs/warscape_pose.json", __dir__))
LIMIT   = opt("limit", "0").to_i
VERBOSE = ARGV.include?("--verbose")

# Enough correspondences per bone pair to pin the transform and make the
# residual check meaningful; more only costs memory. The solver picks its
# triple from the first 24 and checks the residual against all of them.
# Pooling takes only a few correspondences PER MESH. Taking the first 128
# whatever their source would fill the quota from the first one or two meshes
# alphabetically, and the residual would then only ever re-test those - it
# would read EXACT while saying nothing about whether the family agrees.
# A small per-mesh quota makes the residual a genuine cross-mesh check.
CAP_PER_MESH = 8
CAP_TOTAL    = 1024
CAP_MESH     = 24      # per mesh, for the cheap clustering pass
MATCH    = 1e-3        # transforms this close are the same pose
MIN_KEYS = 3           # fewer shared pairs than this proves nothing
CONF_MIN = 0.02        # below this a pair's rotation is not meaningfully determined
FIT_OK   = 1e-3        # a pose reassembles a mesh if no vertex disagrees by more
ROUNDS   = 4           # reassignment passes; it converges in two or three

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

# `testdata.pack` holds dev assets, including a `testdata\euroline\` build of
# euro_line_infantry on a DIFFERENT rig. It is not content the game ships to a
# player, and left in it forms a bogus two-mesh "family" whose pose disagrees
# with itself by 0.14. Excluded by default; --testdata puts it back.
SKIP_PACKS = ARGV.include?("--testdata") ? [] : %w[testdata.pack]

# A mesh is identified by its INTERNAL PATH, not its basename. The same path in
# a later pack is an override of the earlier one - that is how mod packs work,
# and our own zz_chain.pack re-ships four vanilla unit meshes - so the last one
# alphabetically wins, matching what the game actually loads.
def mesh_list(game, limit)
  by_path = {}
  Dir[File.join(game, "data", "*.pack")].sort.each do |pk|
    next if SKIP_PACKS.include?(File.basename(pk).downcase)
    each_pack_entry(pk) do |name, offset, size, _f|
      next unless name.downcase.end_with?(".variant_weighted_mesh")
      by_path[name.downcase.tr("\\", "/")] = [File.basename(name), pk, offset, size]
    end
  end
  out = by_path.values.sort_by { |n, pk, _o, _s| [pk, n] }
  limit > 0 ? out.first(limit) : out
end

def load_mesh(pk, offset, size)
  VWM.read(File.open(pk, "rb") { |f| f.seek(offset); f.read(size) })
end

# correspondences per bone pair, capped per mesh and overall
def gather(m, cap, into = Hash.new { |h, k| h[k] = [] }, total = nil)
  mine = Hash.new(0)
  m[:parts].each do |p|
    p[:verts].each do |v|
      next if v[:infl].size < 2
      v[:infl].combination(2) do |x, y|
        a, b = x[:bone] < y[:bone] ? [x, y] : [y, x]
        key = [a[:bone], b[:bone]]
        next if mine[key] >= cap
        arr = into[key]
        next if total && arr.size >= total
        mine[key] += 1
        arr << [VWM.infl_pos(a), VWM.infl_pos(b)]
      end
    end
  end
  into
end

def solve_all(pool)
  pool.each_with_object({}) { |(k, pts), h| (s = solve_rigid(pts)) && h[k] = s }
end

# Do two solved transform sets describe the same pose? Compared on the pairs
# they BOTH observe, so a mesh that sees few bones can still be placed.
#
# LOW-CONFIDENCE PAIRS ARE EXCLUDED. A pair whose shared vertices are nearly
# collinear has an essentially arbitrary roll, so comparing it says nothing -
# and including such pairs is what shattered `euro_line_infantry`'s four LODs
# across three different "families" when they are measurably the same rig.
def confident(rel) = rel.select { |_, s| (s[:conf] || 1.0) >= CONF_MIN }

def agrees?(a, b)
  common = a.keys & b.keys
  return [false, common.size] if common.size < MIN_KEYS
  ok = common.all? do |k|
    (0..8).all? { |i| (a[k][:r][i] - b[k][:r][i]).abs < MATCH } &&
      norm(sub(a[k][:t], b[k][:t])) < MATCH
  end
  [ok, common.size]
end

# Worst object-space disagreement between the influences of one vertex, under
# a candidate pose. This is the real question - whether the pose reassembles
# this mesh - so it is what family assignment is decided on, rather than a
# proxy. nil when the pose does not cover the mesh's bones at all.
def fit_of(probe, pose)
  worst = 0.0
  tested = 0
  probe.each do |infl|
    ws = infl.map { |bone, p| (po = pose[bone]) && add(mat_mul_vec(po[:r], p), po[:t]) }
    next if ws.any?(&:nil?)
    tested += 1
    (1...ws.size).each { |k| d = norm(sub(ws[0], ws[k])); worst = d if d > worst }
  end
  tested.zero? ? nil : [worst, tested]
end

# HOW MUCH a pose tests matters as much as whether it passes. A pose that
# places 12 bones can only judge the vertices whose bones it covers, and it
# will happily accept a mesh that a 38-bone pose rejects - which is how a
# distorted LOD4 ended up in a sparse family, with only 34 of its 86 probe
# vertices even testable. So the mesh goes to the family with the MOST
# evidence among those that fit, not the first or the largest.
def best_family(families, probe)
  best = nil
  families.each do |fam|
    f = fit_of(probe, fam[:pose]) or next
    worst, tested = f
    next if worst > FIT_OK
    best = [tested, fam] if best.nil? || tested > best[0]
  end
  best&.last
end

# A small sample of multi-influence vertices, kept in memory so assignment can
# be re-tested each round without re-reading 250 MB of geometry.
#
# SAMPLED BY BONE COMBINATION, NOT BY POSITION. Taking the first N vertices -
# the obvious thing - draws them all from the first part, which typically
# involves two or three bones. Such a probe passed `campaign_native_american
# _colonel` into the 800-mesh human family, whose pose is wrong for it by 0.16
# units; the full check caught it, but only after the bad mesh had already
# poisoned the pooled solve.
#
# Every distinct bone combination is a separate claim the mesh makes about the
# skeleton, so a few vertices from each covers all of them for a fraction of
# the memory.
# The same question asked of every vertex rather than a sample.
def full_fit(m, pose)
  worst = nil
  m[:parts].each do |p|
    p[:verts].each do |v|
      next if v[:infl].size < 2
      ws = v[:infl].map { |i| (po = pose[i[:bone]]) && add(mat_mul_vec(po[:r], VWM.infl_pos(i)), po[:t]) }
      next if ws.any?(&:nil?)
      worst ||= 0.0
      (1...ws.size).each { |k| d = norm(sub(ws[0], ws[k])); worst = d if d > worst }
    end
  end
  worst
end

def probe_of(m, per_combo = 3, cap = 600)
  seen = Hash.new(0)
  out = []
  m[:parts].each do |p|
    p[:verts].each do |v|
      next if v[:infl].size < 2
      key = v[:infl].map { |i| i[:bone] }.sort
      next if seen[key] >= per_combo
      seen[key] += 1
      out << v[:infl].map { |i| [i[:bone], VWM.infl_pos(i)] }
      return out if out.size >= cap
    end
  end
  out
end

# ---- pass 1: solve each mesh on its own, then cluster ----------------------
list = mesh_list(GAME, LIMIT)
puts "found #{list.size} meshes"

skipped = Hash.new(0)
per_mesh = []
broken = []
list.each do |name, pk, offset, size|
  m = begin
    load_mesh(pk, offset, size)
  rescue StandardError => e
    skipped[e.class.to_s] += 1
    next
  end
  rel = solve_all(gather(m, CAP_MESH))
  used = m[:parts].flat_map { |p| p[:verts].flat_map { |v| v[:infl].map { |i| i[:bone] } } }.uniq.sort
  mi = { name: name, pk: pk, off: offset, size: size,
         rel: rel, crel: confident(rel), used: used, probe: probe_of(m) }

  # SELF-CONSISTENCY IS CHECKED FIRST, BEFORE ANY FAMILY QUESTION.
  #   The shared-point property - every influence of a vertex describing the
  #   same world point - belongs to the mesh alone. A mesh that breaks it is
  #   not a mesh whose skeleton we have yet to identify; it is a broken mesh,
  #   and the engine will render it stretched between two answers.
  #
  #   Testing it here rather than at family-seed time matters, because a broken
  #   mesh can otherwise slip into a family whose pose places too few bones to
  #   notice. Our big-head euro_line_infantry lod4 did exactly that: only 34 of
  #   its 86 probe vertices were testable against a 12-bone pose, those 34
  #   agreed, and it was accepted - while against a 38-bone pose it is 0.063
  #   out. Checked on its own terms it is rejected outright, whatever else
  #   exists.
  if rel.size >= MIN_KEYS
    own = build_pose(rel, rel.keys.flatten.uniq.sort)
    d = full_fit(m, own)
    if d && d > FIT_OK
      mi[:why] = format("inconsistently skinned - its own influences disagree by %.6f", d)
      broken << mi
      next
    end
  end
  per_mesh << mi
end
puts "  parsed #{per_mesh.size}#{skipped.empty? ? '' : ", skipped #{skipped.inspect}"}"
unless broken.empty?
  puts "  #{broken.size} meshes are not consistently skinned and were excluded:"
  broken.each { |b| puts format("    %-58s %s", b[:name], b[:why]) }
end

# ---- build the families in ONE deterministic pass ---------------------------
# HOW, AND WHY NOT BY ITERATING
#   The obvious approach - guess families, re-solve each from all its members,
#   reassign everyone, repeat - does not settle. It went 85 -> 9 -> 161 -> 8
#   families on the full corpus, because re-solving MOVES the pose, so meshes
#   that fitted a family last round stop fitting it this round and vice versa.
#   It also let a mismatched mesh into the pool and corrupt the solve for the
#   800 that belonged there.
#
#   This builds each family's pose incrementally and NEVER re-solves it. A mesh
#   joins a family only if that family's current pose already reassembles it;
#   joining may EXTEND the pose onto bones it did not cover, but never moves a
#   bone already placed. Since accepted meshes therefore stay accepted, one
#   pass is enough and the result does not depend on iteration count.
#
#   Meshes are taken most-informative-first, so the rigs that can actually
#   define a pose seed the families rather than a four-bone LOD4 doing it.
per_mesh.sort_by! { |mi| -mi[:crel].size }

families = []   # { pose:, members:, seeded_by: }
unmatched = []
#   Note which `rel` is used where. Poses are built from ALL pairs, because the
#   maximum spanning tree already prefers confident edges and will route around
#   a weak one WHEN THERE IS ANOTHER ROUTE; deleting weak edges outright only
#   removes fallbacks and strands bones. Confidence filtering belongs to
#   matching, where a meaningless rotation would otherwise be compared as if it
#   meant something.
#
# Joining and extending are SEPARATE decisions. A mesh joins because the
# family's pose already reassembles it. Extending that pose onto bones the
# family has not placed is a bonus - it buys object-space coverage - and if the
# extension cannot be verified it is simply dropped, rather than the mesh being
# exiled to a fragment family. `euro_line_infantry_lod4` fits the 775-mesh pose
# with zero bad combinations; it was being rejected only because ITS OWN weapon
# bones could not be added safely.
def join(fam, mi)
  before = fam[:pose]
  grown = mi[:rel].empty? ? before : build_pose(mi[:rel], mi[:rel].keys.flatten.uniq, seed: before)
  unless grown.equal?(before)
    # An extension must not break the mesh that prompted it, NOR any mesh
    # already in the family. Checking only the joiner let one bad new bone
    # through and threw a family's own seed mesh 0.14 units out of place.
    ok = (f = fit_of(mi[:probe], grown)).nil? || f[0] <= FIT_OK
    ok &&= fam[:members].all? { |o| (g = fit_of(o[:probe], grown)).nil? || g[0] <= FIT_OK }
    grown = before unless ok
  end
  fam[:pose] = grown
  fam[:members] << mi
  fam
end

per_mesh.each do |mi|
  joined = (fam = best_family(families, mi[:probe])) && join(fam, mi)
  next if joined
  if mi[:crel].size < MIN_KEYS
    mi[:why] = "too few confident bone pairs (#{mi[:crel].size})"
    unmatched << mi
  else
    # Self-consistency was already established in pass 1, so this mesh can
    # define a pose.
    bones = mi[:rel].keys.flatten.uniq.sort
    families << { pose: build_pose(mi[:rel], bones), members: [mi],
                  seeded_by: mi[:name], root: bones.include?(0) ? 0 : bones.min }
  end
end
families.sort_by! { |f| -f[:members].size }
puts "  #{families.size} families before merging"

# ---- merge pass ------------------------------------------------------------
# A single forward pass is order-dependent in one harmless way: a mesh judged
# against the families that existed AT THE TIME can seed its own family, and a
# later-grown family may cover it perfectly. `euro_line_infantry_lod4` ended up
# in an 11-mesh fragment although it fits the 775-mesh pose exactly.
#
# So every member of every smaller family is offered to the larger ones, which
# are now complete. This only ever moves meshes INTO a better-covered pose -
# and it moves none that do not fit, which is why `euro_pirate_officer` stays
# put: its brow bone really does sit 0.005 from where the big family has it.
loop do
  moved = 0
  families.sort_by! { |f| -f[:members].size }
  families.each do |small|
    small[:members].dup.each do |mi|
      others = families.reject { |f| f.equal?(small) }
      big = best_family(others, mi[:probe]) or next
      # only move where there is MORE evidence than the current home provides
      here = fit_of(mi[:probe], small[:pose])
      there = fit_of(mi[:probe], big[:pose])
      next if here && there[1] <= here[1]
      join(big, mi)
      small[:members].delete(mi)
      moved += 1
    end
  end
  families.reject! { |f| f[:members].empty? }
  puts "  merge pass: #{moved} meshes moved, #{families.size} families"
  break if moved.zero?
end

families.sort_by! { |f| -f[:members].size }
puts "  #{families.size} families, #{unmatched.size} meshes not placed"
unmatched.each { |mi| puts format("    %-58s %s", mi[:name], mi[:why]) }

solved = families.map { |fam| [fam, fam[:members]] }

# ---- report and write ------------------------------------------------------
out_families = []
solved.each_with_index do |(s, mem), fi|
  pose = s[:pose]
  used = mem.flat_map { |m| m[:used] }.uniq.sort
  unplaced = used - pose.keys

  # Full check against every vertex of every member - not the 200-vertex probe
  # used for assignment. This is the number that decides whether the pose is
  # usable, so it is measured on everything.
  worst_d = 0.0; worst_name = nil; checked = 0; bad = 0
  mem.each do |mi|
    m = load_mesh(mi[:pk], mi[:off], mi[:size])
    md = 0.0
    m[:parts].each do |p|
      p[:verts].each do |v|
        next if v[:infl].size < 2
        ws = v[:infl].map { |i| (po = pose[i[:bone]]) && add(mat_mul_vec(po[:r], VWM.infl_pos(i)), po[:t]) }
        next if ws.any?(&:nil?)
        checked += 1
        (1...ws.size).each { |k| d = norm(sub(ws[0], ws[k])); md = d if d > md }
      end
    end
    bad += 1 if md > FIT_OK
    if md > worst_d then worst_d = md; worst_name = mi[:name] end
    puts format("    %-58s %.6f", mi[:name], md) if VERBOSE
  end

  puts "\nfamily #{fi}: #{mem.size} meshes, seeded by #{s[:seeded_by].sub(/\.variant_weighted_mesh$/, '')}"
  puts "  e.g. #{mem.first(3).map { |m| m[:name].sub(/\.variant_weighted_mesh$/, '') }.join(', ')}"
  puts "  bones placed #{pose.size} of #{used.size} used, root #{s[:root]}#{unplaced.empty? ? '' : ", unplaced #{unplaced.inspect}"}"
  puts format("  vertices checked %d, worst disagreement %.6f (%s)", checked, worst_d, worst_name)
  puts "  meshes over #{FIT_OK}: #{bad}"
  puts(worst_d < FIT_OK ? "  ONE POSE FITS THIS FAMILY" : "  <-- pose does NOT fit; do not use it")

  out_families << {
    "id"        => fi,
    "meshes"    => mem.size,
    "members"   => mem.map { |m| m[:name] }.sort,
    "seeded_by" => s[:seeded_by],
    "root"      => s[:root],
    "max_vertex_disagreement" => worst_d,
    "fits"     => worst_d < FIT_OK,
    "unplaced" => unplaced,
    "bones"    => pose.keys.sort.to_h { |b| [b.to_s, { "r" => pose[b][:r], "t" => pose[b][:t] }] }
  }
end

fits = out_families.count { |f| f["fits"] }
covered = out_families.select { |f| f["fits"] }.sum { |f| f["meshes"] }
puts "\n#{fits}/#{out_families.size} families fit; #{covered} meshes covered, #{unmatched.size} unplaced"

File.write(OUT, JSON.pretty_generate({
  "format"   => "empire.warscape_pose/2",
  "note"     => "per-skeleton reference poses recovered from shipped mesh geometry (vwm_pose_global.rb), not from .anim",
  "match"    => MATCH,
  "fit_ok"   => FIT_OK,
  "unmatched_meshes" => (unmatched + broken).map { |m| { "name" => m[:name], "why" => m[:why] } },
  "families" => out_families
}))
puts "wrote #{OUT}  (#{out_families.size} families)"
