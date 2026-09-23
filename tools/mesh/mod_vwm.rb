# mod_vwm.rb - Phase 5: make ONE deliberate geometry change to a shipped unit
# mesh, so the writer is proven IN GAME and not only byte-identically.
#
#
# Usage
#   ruby mod_vwm.rb <in.vwm> <out.vwm> --part head --scale 1.6
#   ruby mod_vwm.rb <in> <out> --list

require "json"
require_relative "vwm"
require_relative "vwm_pose"
require_relative "vwm_json"

def opt(n, d = nil)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : d
end
def pname(p) = p[:name].force_encoding("UTF-16LE").encode("UTF-8")

src, dst = ARGV[0], ARGV[1]
abort "usage: ruby mod_vwm.rb <in> <out> --part NAME --scale N" unless src && File.file?(src)

data = File.binread(src)
m = VWM.read(data)
abort "sanity: this file does not round-trip, refusing to modify it" unless VWM.write(m) == data

if ARGV.include?("--list")
  m[:parts].each_with_index do |p, i|
    xs = p[:verts].flat_map { |v| v[:infl].map { |f| VWM.infl_pos(f) } }
    tally = Hash.new(0)
    p[:verts].each { |v| v[:infl].each { |f| tally[f[:bone]] += 1 } }
    top = tally.sort_by { |_, c| -c }.first(3).map { |bone, c| bone.to_s + "(" + c.to_s + ")" }
    puts format("  [%d] %-38s v=%-6d bone-space x %.2f..%.2f y %.2f..%.2f z %.2f..%.2f  bones %s",
                i, pname(p), p[:vc],
                xs.map { |a| a[0] }.min, xs.map { |a| a[0] }.max,
                xs.map { |a| a[1] }.min, xs.map { |a| a[1] }.max,
                xs.map { |a| a[2] }.min, xs.map { |a| a[2] }.max,
                top.join(" "))
  end
  exit 0
end

want  = opt("part", "head")
scale = opt("scale", "1.6").to_f

pose, _resid, source = compute_pose(m)
abort "no usable pose for this mesh - cannot scale safely" if pose.empty?
puts "pose: #{pose.size} bones (#{source})"

targets = m[:parts].select { |p| pname(p).downcase.include?(want.downcase) }
abort "no part matching '#{want}' - run with --list" if targets.empty?

# Scale about the centre of the selected parts IN OBJECT SPACE, so the part
# grows in place instead of being flung away from a bone origin.
pts = targets.flat_map { |p| p[:verts].map { |v| to_object(pose, v[:infl][0]) } }
abort "some vertices have no posed bone - refusing to scale part of a part" if pts.any?(&:nil?)
centre = [0, 1, 2].map { |c| (pts.map { |q| q[c] }.min + pts.map { |q| q[c] }.max) / 2.0 }
puts format("centre of selection (object space): [%.4f %.4f %.4f]", *centre)

hits = 0
moved = 0
max_bytes = 0
targets.each do |p|
  hits += 1
  p[:verts].each do |v|
    unless v[:infl].all? { |f| pose[f[:bone]] }
      abort "vertex uses an unposed bone #{v[:infl].map { |f| f[:bone] }.inspect} - refusing to guess"
    end
    obj = to_object(pose, v[:infl][0])
    want_obj = [0, 1, 2].map { |c| centre[c] + (obj[c] - centre[c]) * scale }
    v[:infl].each do |f|
      VWM.set_infl_pos(f, to_bone(pose, f[:bone], want_obj))
      max_bytes += 12
    end
    moved += 1
  end
  puts format("  scaled %-38s %d vertices x%.2f about the selection centre", pname(p), p[:verts].size, scale)
end

# The property that was broken last time, checked before anything is written:
# every influence of every vertex must still describe ONE world point.
worst = 0.0
m[:parts].each do |p|
  p[:verts].each do |v|
    next if v[:infl].size < 2
    ws = v[:infl].map { |f| to_object(pose, f) }
    next if ws.any?(&:nil?)
    (1...ws.size).each { |k| d = norm(sub(ws[0], ws[k])); worst = d if d > worst }
  end
end
puts format("shared-point check: worst influence disagreement %.8f", worst)
abort "influences disagree by #{worst} - this mesh would render torn; refusing to write" if worst > 1e-3

out = VWM.write(m)
abort "length changed (#{data.bytesize} -> #{out.bytesize}) - the writer is wrong" unless out.bytesize == data.bytesize
diff = data.bytes.zip(out.bytes).count { |a, b| a != b }
puts "parts modified : #{hits}"
puts "vertices moved : #{moved}"
puts "bytes changed  : #{diff} (max possible #{max_bytes})"
abort "changed more bytes than bone-space positions occupy" if diff > max_bytes

File.binwrite(dst, out)
puts "written: #{dst} (#{out.bytesize} bytes)"
