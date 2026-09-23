# subdiv_equip.rb - Phong tessellation for the WEAPONS and worn kit in
# unitmodels\euro_equipment.variant_weighted_mesh (see equip_vwm.rb for the
# container).
#
# WHY THIS IS A SEPARATE TOOL FROM subdiv_vwm.rb
#   Equipment is RIGID. A weapon hangs off a single Weapon bone and its vertex
#   is 20 flat floats with no influence blocks, so there is no bone space, no
#   pose to solve, and no shared-point validity property to preserve. Every
#   trap subdiv_vwm.rb exists to avoid simply does not arise here. What DOES
#   carry over is the uv-seam weld. The boundary needs no pinning here: this
#   tool never moves an original vertex at all.
#
#   THE VERTEX
#     f0-2   position (object space)      <- the only thing tessellation sets
#     f3-5   normal        (unit)
#     f6-7   uv
#     f8-10  tangent       (unit)
#     f11-13 binormal      (unit)
#     f14-17 vertex colour (1,1,1,1 throughout)
#     f18-19 constant per sub-model
#
# THERE ARE NO EQUIPMENT LODs. One container serves every distance, so unlike
# a body - where lod3/lod4 stay vanilla and cost nothing past 400 units -
# anything added here is paid at every distance, on every man. That is why the
# default target list is narrow rather than "all 134". Read the cost line this
# prints before widening it.
#
# Usage
#   ruby subdiv_equip.rb <in> <out> [--only REGEX] [--steps N] [--linear]
#   ruby subdiv_equip.rb <in> --plan            cost it without writing

require_relative "vwm"
require_relative "equip_vwm"

require_relative "subdiv_prop_lib"

# ---- driver ----------------------------------------------------------------
inp = ARGV[0]
abort "usage: subdiv_equip.rb <in> <out> [--only REGEX] [--steps N] [--linear]" unless inp
plan   = ARGV.include?("--plan")
out_p  = (plan ? nil : ARGV[1])
i = ARGV.index("--only");  only  = i ? Regexp.new(ARGV[i+1]) : DEFAULT_ONLY
i = ARGV.index("--steps"); steps = i ? ARGV[i+1].to_i : 1
linear = ARGV.include?("--linear")

outer = VWM.read(File.binread(inp))
m     = EquipVWM.read(outer[:trailer])

before_v = m[:subs].sum { |s| s[:verts].size }
before_t = m[:subs].sum { |s| s[:idx].bytesize / 12 }

hit = []
m[:subs] = m[:subs].map do |s|
  nm = EquipVWM.name_of(s)
  next s unless nm =~ only
  v0, t0 = s[:verts].size, s[:idx].bytesize / 12
  steps.times { s = subdivide_sub(s, linear: linear) }
  hit << [nm, v0, s[:verts].size, t0, s[:idx].bytesize / 12]
  s
end

puts "matched #{hit.size} of #{m[:subs].size} sub-models  (pattern #{only.source})"
hit.sort_by { |h| -h[4] }.each do |nm, v0, v1, t0, t1|
  printf("  %-34s %5d -> %6d verts   %5d -> %6d tris\n", nm, v0, v1, t0, t1)
end
after_v = m[:subs].sum { |s| s[:verts].size }
after_t = m[:subs].sum { |s| s[:idx].bytesize / 12 }
puts
printf("container total: %d -> %d verts (%.2fx), %d -> %d tris (%.2fx)\n",
       before_v, after_v, after_v.to_f/before_v, before_t, after_t, after_t.to_f/before_t)

if plan
  puts "\n--plan: nothing written"
else
  data = VWM.write(outer.merge(trailer: EquipVWM.write(m)))
  File.binwrite(out_p, data)
  puts "\nwrote #{out_p} (#{data.bytesize} bytes)"
  # re-read what we just wrote: the container must still parse and re-emit exactly
  chk = VWM.read(File.binread(out_p))
  back = VWM.write(chk.merge(trailer: EquipVWM.write(EquipVWM.read(chk[:trailer]))))
  puts back == data ? "re-read round-trip: BYTE-IDENTICAL" : "re-read round-trip: FAILED"
end

# edge classification, printed after the run so the honesty of the result is visible
if $smooth_edges
  tot = $smooth_edges + $hard_edges
  printf("\nedges: %d smooth (%.1f%%), %d crease/cap left at midpoint, %d clamped by MAX_BULGE\n",
         $smooth_edges, 100.0 * $smooth_edges / tot, $hard_edges, $clamped_edges)
end
