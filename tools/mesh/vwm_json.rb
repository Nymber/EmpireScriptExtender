# vwm_json.rb - convert .variant_weighted_mesh to/from a JSON intermediate,
# so a real 3D tool can read and write Empire unit geometry.
#
#
# WHY FLOATS ARE WRITTEN WITH 9 SIGNIFICANT DIGITS
#   The gate for this layer is the same as for the format: mesh -> JSON ->
#   mesh must come back BYTE-IDENTICAL. A lossy interchange is a silent
#   corruption, and "it looked right in Blender" is not evidence.
#
#   9 significant decimal digits is exactly the number that uniquely
#   determines an IEEE-754 single, so %.9g round-trips a float32 through
#   decimal without loss. Fewer digits would quietly perturb vertices;
#   storing raw hex would be exact but unreadable and useless to a 3D tool.
#
#   NaN and Infinity have no decimal form, so those fall back to an explicit
#   {"hex": "..."} object rather than being silently mangled.
#
# WHAT IS INTERPRETED vs CARRIED
#   Interpreted (what an artist edits): UV, per-influence bone / position /
#   normal / weight, triangle indices.
#   Carried verbatim: the other six floats of the vertex head (meaning still
#   unknown - probably tangent/bitangent), the 16-byte vertex tail, the
#   material parameter blocks and the file trailer. Unknown data is preserved,
#   never invented.
#
# Usage
#   ruby vwm_json.rb tojson <in.vwm>  <out.json>
#   ruby vwm_json.rb tovwm  <in.json> <out.vwm>
#   ruby vwm_json.rb roundtrip <in.vwm>      # the gate: vwm -> json -> vwm

require "json"
require_relative "vwm"
require_relative "vwm_pose"

# ---- pose: bone-space <-> object-space --------------------------------------
# Recovered FROM THE MESH (see vwm_pose.rb): each influence of a vertex stores
# the same world point in a different bone's frame, so shared vertices give the
# relative bone transforms exactly. Residual across a whole unit is ~1e-8.
#
# With the pose in hand a vertex has a real object-space position, which is
# what a 3D tool needs - and an edited position converts back per influence:
#     p_bone = R^-1 * (p_object - t)
#
# The pose is preferably the SHARED one solved across the whole corpus
# (docs/warscape_pose.json, built by vwm_pose_global.rb). Two reasons to prefer
# it over solving each mesh alone:
#
#   COVERAGE. A bone is only locatable from a mesh that blends it with another.
#   euro_line_infantry_lod1 cannot place bone 23 (Eyes) - all its eye vertices
#   are single-influence - and lower LODs are worse, because simplification
#   removes exactly the blended vertices. Pooled across 795 meshes, the gaps
#   close.
#
#   AGREEMENT BETWEEN LODs. All four LODs of a unit ship together. Solved
#   separately they differ by ~1e-6, so an edit converted through one LOD's
#   pose would not match the next. One pose for all of them removes the
#   question.
#
# The right family is chosen by FIT, not by a name lookup, so a mesh this tool
# has never seen - including one we generate - is handled the same way.
POSE_FILE = File.expand_path("../../docs/warscape_pose.json", __dir__)

def solve_pose_from_mesh(m)
  rel = {}
  bone_pairs(m).each { |key, pts| (s = solve_rigid(pts)) && rel[key] = s }
  seen = rel.keys.flatten.uniq.sort
  return [{}, nil] if seen.empty?
  [build_pose(rel, seen), rel.values.map { |s| s[:err] }.max]
end

# Sampled by BONE COMBINATION, three per combination: every distinct
# combination is a separate claim the mesh makes about the skeleton, so this
# tests all of them while staying bounded. Walking every vertex against every
# family instead makes a corpus-wide run needlessly slow for no more certainty.
def pose_probe(m, per_combo = 3)
  seen = Hash.new(0)
  out = []
  m[:parts].each do |p|
    p[:verts].each do |v|
      next if v[:infl].size < 2
      key = v[:infl].map { |i| i[:bone] }.sort
      next if seen[key] >= per_combo
      seen[key] += 1
      out << v[:infl].map { |i| [i[:bone], VWM.infl_pos(i)] }
    end
  end
  out
end

def probe_fit(probe, pose)
  worst = 0.0
  tested = 0
  probe.each do |infl|
    ws = infl.map { |b, p| (po = pose[b]) && add(mat_mul_vec(po[:r], p), po[:t]) }
    next if ws.any?(&:nil?)
    tested += 1
    (1...ws.size).each { |k| d = norm(sub(ws[0], ws[k])); worst = d if d > worst }
  end
  tested.zero? ? nil : [worst, tested]
end

# Parsed once; a corpus run calls this a thousand times.
def pose_families
  @pose_families ||=
    if File.file?(POSE_FILE)
      JSON.parse(File.read(POSE_FILE))["families"].map do |f|
        [f["id"], f["bones"].to_h { |b, v| [b.to_i, { r: v["r"].map(&:to_f), t: v["t"].map(&:to_f) }] }]
      end
    else
      []
    end
end

def compute_pose(m)
  unless pose_families.empty?
    probe = pose_probe(m)
    best = nil
    pose_families.each do |id, pose|
      fit = probe_fit(probe, pose) or next
      worst, tested = fit
      next if worst > 1e-3
      # most evidence wins: a pose placing few bones can only judge few
      # vertices, and would accept a mesh a better-covered pose rejects
      best = [tested, pose, worst, id] if best.nil? || tested > best[0]
    end
    return [best[1], best[2], "family #{best[3]}"] if best
  end
  # No shared pose, or none of them describes this mesh - solve it alone and
  # say so, rather than silently using a pose that does not fit.
  pose, resid = solve_pose_from_mesh(m)
  [pose, resid, "solved from this mesh alone"]
end

def to_object(pose, infl)
  po = pose[infl[:bone]] or return nil
  add(mat_mul_vec(po[:r], VWM.infl_pos(infl)), po[:t])
end

def to_bone(pose, bone, obj)
  po = pose[bone] or return nil
  mat_mul_vec(mat_t(po[:r]), sub(obj, po[:t]))
end

def to_object_dir(pose, infl)
  po = pose[infl[:bone]] or return nil
  mat_mul_vec(po[:r], VWM.infl_normal(infl))
end

def to_bone_dir(pose, bone, dir)
  po = pose[bone] or return nil
  mat_mul_vec(mat_t(po[:r]), dir)
end

# Object-space values are stored ROUNDED TO FLOAT32, deliberately.
# Blender holds vertex coordinates as float32, so a vertex nobody touched comes
# back with the identical bits and compares equal to 0.0 - which is what makes
# "was this vertex edited?" a sharp question rather than a tolerance guess.
def f32(x) = [x].pack("e").unpack1("e")
def f32a(v) = v.map { |x| f32(x) }

# Margin above float32 round-off, far below any edit a person would make
# (the whole figure spans ~2.0 units, so this is 0.00005% of it).
MOVE_EPS = 1e-6

def pose_to_json(pose, resid, unplaced, source)
  { "note"     => "recovered from shipped geometry, not from the .anim - see vwm_pose.rb",
    "source"   => source,
    "residual" => resid,
    "unplaced" => unplaced,
    "bones"    => pose.keys.sort.to_h { |b| [b.to_s, { "r" => pose[b][:r], "t" => pose[b][:t] }] } }
end

def pose_from_json(j)
  return {} unless j.is_a?(Hash) && j["bones"]
  j["bones"].to_h { |b, v| [b.to_i, { r: v["r"].map(&:to_f), t: v["t"].map(&:to_f) }] }
end

# ---- exact float <-> decimal ------------------------------------------------
def f_enc(bits)                       # 4 raw bytes -> JSON value
  v = bits.unpack1("e")
  return { "hex" => bits.unpack1("H8") } unless v.finite?
  # %.9g uniquely determines a float32; verify rather than trust
  s = format("%.9g", v)
  return { "hex" => bits.unpack1("H8") } unless [s.to_f].pack("e") == bits
  s.to_f
end

def f_dec(j)                          # JSON value -> 4 raw bytes
  return [j["hex"]].pack("H8") if j.is_a?(Hash)
  [j.to_f].pack("e")
end

def f_enc_ary(raw) = raw.bytes.each_slice(4).map { |b| f_enc(b.pack("C4")) }
def f_dec_ary(a)   = a.map { |j| f_dec(j) }.join

def utf16(b) = b.force_encoding("UTF-16LE").encode("UTF-8")
def utf8(s)  = s.encode("UTF-16LE").b

# ---- vwm -> json -----------------------------------------------------------
def to_json_doc(m)
  pose, resid, source = compute_pose(m)
  used = m[:parts].flat_map { |p| p[:verts].flat_map { |v| v[:infl].map { |i| i[:bone] } } }.uniq.sort
  unplaced = used - pose.keys

  {
    "format"  => "empire.variant_weighted_mesh/1",
    "version" => m[:version],
    "pose"    => pose_to_json(pose, resid, unplaced, source),
    "scalars" => m[:scalars].map { |n, v| { "name" => utf16(n), "value" => f_enc(v) } },
    "vec4s"   => m[:vec4s].map   { |n, v| { "name" => utf16(n), "value" => f_enc_ary(v) } },
    "parts"   => m[:parts].map do |p|
      {
        "name"     => utf16(p[:name]),
        "vertices" => p[:verts].map do |v|
          head = v[:head].bytes.each_slice(4).map { |b| f_enc(b.pack("C4")) }
          o    = to_object(pose, v[:infl][0])
          n    = to_object_dir(pose, v[:infl][0])
          rec = {
            "uv"      => head[0, 2],          # atlas UV - the only known pair
            "head6"   => head[2, 6],          # carried verbatim, meaning unknown
            "infl"    => v[:infl].map do |i|
              { "bone"   => i[:bone],
                "pos"    => f_enc_ary(i[:mid][0, 12]),
                "normal" => f_enc_ary(i[:mid][12, 12]),
                "weight" => f_enc(i[:weight]) }
            end,
            "tail"    => v[:tail].unpack1("H32")
          }
          if o
            rec["obj"] = f32a(o)
            rec["nrm"] = f32a(n)
            # An edit can only be written back if EVERY influencing bone has a
            # pose. Say so per vertex rather than discovering it at export.
            rec["locked"] = true unless v[:infl].all? { |i| pose[i[:bone]] }
          end
          rec
        end,
        "indices"  => p[:idx].unpack("V*")
      }
    end,
    "trailer" => m[:trailer].unpack1("H*")
  }
end

# ---- json -> vwm -----------------------------------------------------------
$vwm_moved = 0     # how many vertices came back with a changed object position

# An edited vertex is rewritten IN EVERY BONE SPACE; an untouched one keeps its
# original bytes verbatim. That is what lets a no-op trip stay byte-identical
# while a real edit still lands - the alternative, recomputing every vertex from
# its object position, would rewrite 2.5 million vertices with float noise and
# destroy the one gate this project trusts.
def rebuild_infl(v, pose)
  carried = v["infl"].map do |i|
    { bone: i["bone"],
      mid: f_dec_ary(i["pos"]) + f_dec_ary(i["normal"]),
      weight: f_dec(i["weight"]) }
  end
  return carried unless v["obj"] && !pose.empty?

  was = to_object(pose, carried[0]) or return carried
  now = v["obj"].map(&:to_f)
  nrm_was = to_object_dir(pose, carried[0])
  nrm_now = v["nrm"] ? v["nrm"].map(&:to_f) : nrm_was
  moved   = norm(sub(now, was)) > MOVE_EPS
  renorm  = nrm_was && norm(sub(nrm_now, nrm_was)) > MOVE_EPS
  return carried unless moved || renorm

  if v["locked"]
    abort "vertex moved but one of its bones has no pose (bones #{carried.map { |c| c[:bone] }.inspect}) - refusing to guess"
  end
  $vwm_moved += 1
  carried.map do |c|
    p = moved  ? to_bone(pose, c[:bone], now)      : VWM.infl_pos(c)
    n = renorm ? to_bone_dir(pose, c[:bone], nrm_now) : VWM.infl_normal(c)
    { bone: c[:bone], mid: p.pack("e3") + n.pack("e3"), weight: c[:weight] }
  end
end

def from_json_doc(j)
  pose = pose_from_json(j["pose"])
  {
    version: j["version"],
    scalars: j["scalars"].map { |s| [utf8(s["name"]), f_dec(s["value"])] },
    vec4s:   j["vec4s"].map   { |s| [utf8(s["name"]), f_dec_ary(s["value"])] },
    parts:   j["parts"].map do |p|
      verts = p["vertices"].map do |v|
        {
          head: f_dec_ary(v["uv"]) + f_dec_ary(v["head6"]),
          infl: rebuild_infl(v, pose),
          tail: [v["tail"]].pack("H32")
        }
      end
      { name: utf8(p["name"]), vc: verts.size, ic: p["indices"].size,
        verts: verts, idx: p["indices"].pack("V*") }
    end,
    trailer: [j["trailer"]].pack("H*")
  }
end

# ---- driver ----------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
mode, inp, outp = ARGV[0], ARGV[1], ARGV[2]
case mode
when "tojson"
  m = VWM.read(File.binread(inp))
  doc = to_json_doc(m)
  File.write(outp, JSON.pretty_generate(doc))
  tot = m[:parts].sum { |p| p[:vc] }
  ed  = m[:parts].sum { |p| p[:verts].count { |v| v[:infl].size >= 1 } }
  posed = doc["parts"].sum { |p| p["vertices"].count { |v| v["obj"] } }
  lock  = doc["parts"].sum { |p| p["vertices"].count { |v| v["locked"] } }
  puts "#{outp}: #{m[:parts].size} parts, #{tot} vertices"
  puts "  pose: #{doc['pose']['bones'].size} bones placed (#{doc['pose']['source']})" \
       "#{doc['pose']['unplaced'].empty? ? '' : ", unplaced #{doc['pose']['unplaced'].inspect}"}"
  puts "  object space: #{posed}/#{tot} vertices#{lock.zero? ? '' : "  (#{lock} not editable)"}"
  _ = ed
when "tovwm"
  d = VWM.write(from_json_doc(JSON.parse(File.read(inp))))
  File.binwrite(outp, d)
  puts "#{outp}: #{d.bytesize} bytes, #{$vwm_moved} vertices rebuilt from object space"
when "roundtrip"
  orig = File.binread(inp)
  doc  = to_json_doc(VWM.read(orig))
  back = VWM.write(from_json_doc(JSON.parse(JSON.generate(doc))))
  if back == orig
    puts "BYTE-IDENTICAL  (#{orig.bytesize} bytes, #{$vwm_moved} rebuilt)"
  else
    puts "DIFFERS: #{orig.bytesize} vs #{back.bytesize}"
    n = orig.bytes.zip(back.bytes).each_with_index.count { |(a, b), _| a != b }
    first = orig.bytes.zip(back.bytes).each_with_index.find { |(a, b), _| a != b }
    puts "  #{n} bytes differ, first at offset #{first[1]}" if first
  end
when "movetest"
  # THE PHASE 4b GATE. Move exactly ONE vertex in object space and require
  # that only that vertex's influence positions change in the file - proving
  # both that an edit lands and that nothing else is disturbed.
  orig = File.binread(inp)
  doc  = to_json_doc(VWM.read(orig))
  dx   = (ARGV[2] || "0.05").to_f
  tgt  = doc["parts"].each_with_index.find { |p, _| p["vertices"].any? { |v| v["obj"] && !v["locked"] && v["infl"].size > 1 } }
  abort "no editable multi-bone vertex found" unless tgt
  part, pidx = tgt
  vidx = part["vertices"].index { |v| v["obj"] && !v["locked"] && v["infl"].size > 1 }
  v = part["vertices"][vidx]
  before = v["infl"].map { |i| i["pos"].dup }
  v["obj"] = [f32(v["obj"][0] + dx), v["obj"][1], v["obj"][2]]
  back = VWM.write(from_json_doc(JSON.parse(JSON.generate(doc))))

  puts "moved part #{pidx} (#{part['name']}) vertex #{vidx}, #{v['infl'].size} influences, +#{dx} on axis 0"
  puts "  vertices rebuilt: #{$vwm_moved}#{$vwm_moved == 1 ? '  (exactly one)' : '  <-- expected 1'}"
  # re-read the written file and check the edit landed where it should
  chk = to_json_doc(VWM.read(back))
  cv  = chk["parts"][pidx]["vertices"][vidx]
  d   = norm(sub(cv["obj"].map(&:to_f), v["obj"].map(&:to_f)))
  puts format("  object position after write-back: %.8f from target%s", d, d < 1e-5 ? "   LANDED" : "   <-- WRONG")
  after = cv["infl"].map { |i| i["pos"] }
  changed = before.each_index.count { |i| before[i] != after[i] }
  puts "  influence positions changed: #{changed} of #{before.size}#{changed == before.size ? '  (all, as required)' : '  <-- expected all'}"
  diff = orig.bytes.zip(back.bytes).each_with_index.count { |(a, b), _| a != b }
  puts "  file bytes differing: #{diff}  (#{before.size} influences x 12 bytes = #{before.size * 12} max)"
  puts diff <= before.size * 12 && diff > 0 ? "  ONLY THAT VERTEX CHANGED" : "  <-- collateral damage"
else
  puts "usage: ruby vwm_json.rb tojson|tovwm|roundtrip|movetest <in> [out]"
end
end
