# decode_vwm.rb - incrementally decode Empire's .variant_weighted_mesh (unit
# geometry), the format that gates high-poly unit models.
#
# WHY IT IS WORTH DECODING
#   Unit meshes are the ONE art format this project cannot write. Buildings
#   are solved (rigid_model round-trips byte-identically); the community tools
#   here cover only Napoleon/Shogun 2. But a unit mesh opens with magic
#   78 56 34 12 - the SAME container as rigid_model's inner mesh, which sits
#   at offset 4 after a [u4 mesh count]. So this is a relative, not an alien.
#
#   rigid_mesh.rb's layout, for comparison:
#       [u4_ary of (bool,str)][u4 = 0][u4_ary of 20 floats][u4_ary of u4]
#   where the 20-float vertex is position/normal/UV/tangent/bitangent and
#   SIX ALWAYS-ZERO SLOTS where bone data would live. A weighted mesh
#   presumably fills exactly those.
#
# METHOD
#   Walk block by block, print what is certain, and HEX-DUMP the moment a
#   field stops making sense rather than inventing a reading. Every count is
#   sanity-checked against the remaining bytes, because a misread length turns
#   the rest of the file into confident nonsense.
#
# Usage
#   ruby decode_vwm.rb <file.variant_weighted_mesh> [--max N]

path = ARGV[0]
abort "usage: ruby decode_vwm.rb <file> [--max N]" unless path && File.file?(path)
maxshow = (ARGV.index("--max") ? ARGV[ARGV.index("--max") + 1].to_i : 12)

d = File.binread(path)
$pos = 0
def u4(d) = (v = d[$pos, 4].unpack1("V"); $pos += 4; v)
def u2(d) = (v = d[$pos, 2].unpack1("v"); $pos += 2; v)
def f4(d) = (v = d[$pos, 4].unpack1("e"); $pos += 4; v)
def str(d)
  len = u2(d)
  return nil if len > 500
  s = d[$pos, len * 2]
  $pos += len * 2
  s.force_encoding("UTF-16LE").encode("UTF-8") rescue "<bad utf16>"
end
def dump(d, at, rows = 4)
  rows.times do |r|
    o = at + r * 16
    break if o >= d.bytesize
    hex = d[o, 16].to_s.bytes.map { |b| "%02X" % b }.join(" ")
    asc = d[o, 16].to_s.bytes.map { |b| (b >= 32 && b < 127) ? b.chr : "." }.join
    puts format("      %06d  %-47s %s", o, hex, asc)
  end
end

puts "file  : #{File.basename(path)}  #{d.bytesize} bytes"
magic = d[0, 4].bytes.map { |b| "%02X" % b }.join(" ")
puts "magic : #{magic}#{magic == '78 56 34 12' ? '  (same container as rigid_model)' : '  UNEXPECTED'}"
$pos = 4

puts "\n[0x04] u4 = #{u4(d)}"

n1 = u4(d)
puts "[scalar params] count = #{n1}"
abort "implausible count" if n1 > 1000
n1.times do |i|
  nm = str(d); v = f4(d)
  puts format("    %-24s %s", nm, v) if i < maxshow
end
puts "    ... (#{n1 - maxshow} more)" if n1 > maxshow
puts "  -> pos #{$pos}"

n2 = u4(d)
puts "\n[vec4 params] count = #{n2}"
abort "implausible count" if n2 > 1000
n2.times do
  nm = str(d)
  v = 4.times.map { f4(d) }
  puts format("    %-24s (%s)", nm, v.map { |x| x.round(3) }.join(", "))
end
puts "  -> pos #{$pos}"

# ---- whatever follows: textures? -------------------------------------------
save = $pos
n3 = u4(d)
puts "\n[next u4] = #{n3}  at #{save}"
if n3 > 0 && n3 < 64
  ok = true
  names = []
  n3.times do
    s = str(d)
    if s.nil?
      ok = false
      break
    end
    names << s
  end
  if ok && names.all? { |s| s =~ /\A[\x20-\x7e]*\z/ }
    puts "  reads as #{n3} string(s) - texture/material slots:"
    names.each_with_index { |s, i| puts format("    [%d] %s", i, s.inspect) }
    puts "  -> pos #{$pos}"
  else
    puts "  does NOT read as a string list; rewinding"
    $pos = save
  end
else
  $pos = save
end

puts "\n=== undecoded from #{$pos} (#{d.bytesize - $pos} bytes remain) ==="
dump(d, $pos, 6)

# A vertex array would be [u4 count][count * stride]. Test which strides
# divide the remainder cleanly enough to be plausible.
rem_at = $pos
cand = d[rem_at, 4].unpack1("V")
puts "\nif the next u4 (#{cand}) is a VERTEX COUNT, the stride would be:"
if cand > 0 && cand < 1_000_000
  after = d.bytesize - rem_at - 4
  [32, 36, 40, 44, 48, 52, 56, 64, 72, 80].each do |st|
    used = cand * st
    next if used > after
    left = after - used
    puts format("    stride %2d bytes (%2d floats) -> %d used, %d left over", st, st / 4, used, left)
  end
else
  puts "    (#{cand} is not a plausible count)"
end
