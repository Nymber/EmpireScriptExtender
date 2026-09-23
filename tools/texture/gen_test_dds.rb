# gen_test_dds.rb - build garish synthetic DXT1 test textures.
#
# WHY
#   The first texture test swapped one faction's unit texture for another's and
#   asked "did it change colour?". That was a bad probe twice over: Empire
#   multiplies the diffuse by a per-faction colour in the shader
#   (weighted.fx: `faction_overlay = v.faction_colour * colour.rgb`), so the
#   coat colour never comes from the texture at all - only the facings do. The
#   real difference was green trim vs blue trim, which is far too subtle to
#   read off a screenshot, and it got misread as a failure two runs running.
#
#   So: no subtle probes. Solid saturated colours and huge checks.
#
# THE MIP TRICK
#   A 2048 texture whose TOP mip differs from every mip below it answers three
#   questions from one unit:
#       checkerboard  -> the 2048 top mip is being sampled. 2048 works.
#       solid magenta -> the file loaded but the top mip was skipped/clamped.
#       normal        -> the file was not used at all.
#   That beats any pass/fail probe, which cannot separate the last two.
#
# Usage
#   ruby gen_test_dds.rb checker2048 <out.dds>
#   ruby gen_test_dds.rb solid1024   <out.dds> <r> <g> <b>

def rgb565(r, g, b) = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

# A DXT1 block of one flat colour: c0 == c1 and all indices 0.
# c0 == c1 selects the 3-colour mode, where index 0 is still colour0, so the
# block is solid and the punch-through alpha slot is simply never referenced.
def solid_block(c) = [c, c, 0, 0].pack("vvVx0")[0, 4] + "\0\0\0\0"

def flat_mip(w, h, c)
  bw, bh = [(w + 3) / 4, 1].max, [(h + 3) / 4, 1].max
  solid_block(c) * (bw * bh)
end

def checker_mip(w, h, c1, c2, check_px)
  bw, bh = [(w + 3) / 4, 1].max, [(h + 3) / 4, 1].max
  cb = [check_px / 4, 1].max        # check size in blocks
  out = String.new
  bh.times do |by|
    bw.times do |bx|
      out << solid_block(((bx / cb) + (by / cb)).even? ? c1 : c2)
    end
  end
  out
end

def header(w, h, mips, top_bytes)
  hdr = "DDS ".b + "\0" * 124
  hdr[4, 4]   = [124].pack("V")                       # dwSize
  hdr[8, 4]   = [0x0002100F].pack("V")                # caps|height|width|pixelformat|mipmapcount|linearsize
  hdr[12, 4]  = [h].pack("V")
  hdr[16, 4]  = [w].pack("V")
  hdr[20, 4]  = [top_bytes].pack("V")
  hdr[28, 4]  = [mips].pack("V")
  hdr[76, 4]  = [32].pack("V")                        # pf size
  hdr[80, 4]  = [0x4].pack("V")                       # DDPF_FOURCC
  hdr[84, 4]  = "DXT1"
  hdr[108, 4] = [0x401008].pack("V")                  # complex|texture|mipmap
  hdr
end

MAGENTA = rgb565(255, 0, 255)
GREEN   = rgb565(0, 255, 0)
BLACK   = rgb565(0, 0, 0)

mode, out = ARGV[0], ARGV[1]
abort "usage: gen_test_dds.rb [checker2048|solid1024] <out.dds> [r g b]" unless out

case mode
when "checker2048"
  # top mip: big green/black checks.  every mip below: solid magenta.
  top = checker_mip(2048, 2048, GREEN, BLACK, 64)
  body = top.dup
  w = 1024
  10.times { body << flat_mip(w, w, MAGENTA); w /= 2 }
  data = header(2048, 2048, 11, top.bytesize) + body
when "ladder2048", "ladder1024"
  # ONE COLOUR PER RESOLUTION, so the rendered colour reads back the exact mip
  # the engine chose. A pass/fail probe cannot separate "the top level does not
  # exist" from "the camera is not close enough to warrant it"; this can.
  ladder = { 2048 => rgb565(0,255,0), 1024 => rgb565(255,0,0), 512 => rgb565(0,0,255),
             256 => rgb565(255,255,0), 128 => rgb565(255,255,255), 64 => rgb565(0,0,0) }
  top = mode == "ladder2048" ? 2048 : 1024
  n = mode == "ladder2048" ? 11 : 10
  body = String.new
  w = top
  n.times { body << flat_mip(w, w, ladder[w] || MAGENTA); w /= 2 }
  data = header(top, top, n, (top/4)**2 * 8) + body
when "solid1024"
  r, g, b = (ARGV[2] || 0).to_i, (ARGV[3] || 255).to_i, (ARGV[4] || 255).to_i
  c = rgb565(r, g, b)
  body = String.new
  w = 1024
  10.times { body << flat_mip(w, w, c); w /= 2 }
  data = header(1024, 1024, 10, (1024 / 4)**2 * 8) + body
else
  abort "unknown mode #{mode}"
end

File.binwrite(out, data)

# verify against the shipped 1024 layout so a malformed file cannot be blamed
exp = 128
w, n = (mode =~ /2048/ ? [2048, 11] : [1024, 10])
n.times { b = [(w + 3) / 4, 1].max; exp += b * b * 8; w /= 2 }
puts "#{File.basename(out)}: #{data.bytesize} bytes (expected #{exp}) #{data.bytesize == exp ? 'OK' : 'SIZE MISMATCH'}"
abort "size mismatch" unless data.bytesize == exp
