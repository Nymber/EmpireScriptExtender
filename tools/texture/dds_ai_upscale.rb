# dds_ai_upscale.rb - the one step that actually ADDS detail.
#
#   .dds --decode--> PNG --Real-ESRGAN x4--> PNG --Lanczos /2--> DXT --> .dds
#
# WHY THIS EXISTS
#   `dds_resample.rb up2x` produces a bigger texture with exactly the
#   information the 1024 already had, and that measured as adding NOTHING in
#   game (same unit, same framing: mean luminance gradient 12.58 -> 12.54).
#   A higher mip interpolated from a 1024 source has nothing extra to reveal.
#   Real detail has to be invented by a model; everything else in this
#   toolchain is plumbing around that one step.
#
#   x4 then downsample to x2, rather than asking for x2 directly: the model is
#   trained at x4, and downsampling its output averages away the worst of its
#   hallucination while keeping the structure it recovered.
#
# ALPHA
#   Real-ESRGAN is an RGB model. DXT5 sources (every normal and gloss map) carry
#   real data in alpha, so alpha is NOT sent through the model - it is carried
#   separately and Lanczos-resampled to the target size. Feeding a normal map's
#   alpha to a photo model would invent surface detail that contradicts the RGB
#   channels it is supposed to agree with.
#
# Usage
#   ruby dds_ai_upscale.rb <in.dds> <out.dds> [--exe PATH] [--model NAME]

require "tmpdir"
require_relative "dds_resample_lib"

# ---------- minimal PNG ------------------------------------------------------
require "zlib"

def png_write(path, w, h, px, alpha: false)
  bpp = alpha ? 4 : 3
  raw = String.new(capacity: (w * bpp + 1) * h)
  h.times do |y|
    raw << "\0"
    row = String.new(capacity: w * bpp)
    w.times do |x|
      v = px[y * w + x]
      row << ((v >> 16) & 255) << ((v >> 8) & 255) << (v & 255)
      row << ((v >> 24) & 255) if alpha
    end
    raw << row
  end
  chunk = ->(t, data) { [data.bytesize].pack("N") + t + data + [Zlib.crc32(t + data)].pack("N") }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b +
    chunk.("IHDR", [w, h].pack("NN") + [8, alpha ? 6 : 2, 0, 0, 0].pack("C5")) +
    chunk.("IDAT", Zlib::Deflate.deflate(raw)) + chunk.("IEND", ""))
end

def png_read(path)
  d = File.binread(path)
  raise "not a PNG" unless d[0, 8] == "\x89PNG\r\n\x1a\n".b
  pos = 8; idat = String.new; w = h = depth = ctype = nil
  while pos < d.bytesize
    len = d[pos, 4].unpack1("N"); type = d[pos + 4, 4]
    body = d[pos + 8, len]
    case type
    when "IHDR"
      w, h, depth, ctype = body.unpack("NNCC")
      raise "only 8-bit PNG (got #{depth})" unless depth == 8
      raise "only RGB/RGBA PNG (got colour type #{ctype})" unless [2, 6].include?(ctype)
    when "IDAT" then idat << body
    when "IEND" then break
    end
    pos += 12 + len
  end
  bpp = ctype == 6 ? 4 : 3
  raw = Zlib::Inflate.inflate(idat)
  stride = w * bpp
  px = Array.new(w * h, 0)
  prev = "\0".b * stride
  off = 0
  h.times do |y|
    ft = raw[off].ord; off += 1
    line = raw[off, stride].dup; off += stride
    b = line.bytes
    p = prev.bytes
    # PNG filters are defined on the RECONSTRUCTED bytes of this row, so this
    # has to run left to right in place - vectorising it is what breaks naive
    # decoders on filter types 3 and 4.
    case ft
    when 0 then
    when 1 then (bpp...stride).each { |i| b[i] = (b[i] + b[i - bpp]) & 255 }
    when 2 then (0...stride).each { |i| b[i] = (b[i] + p[i]) & 255 }
    when 3 then (0...stride).each { |i| a = i >= bpp ? b[i - bpp] : 0; b[i] = (b[i] + ((a + p[i]) >> 1)) & 255 }
    when 4 then
      (0...stride).each do |i|
        a  = i >= bpp ? b[i - bpp] : 0
        bb = p[i]
        c  = i >= bpp ? p[i - bpp] : 0
        pp = a + bb - c
        pa, pb, pc = (pp - a).abs, (pp - bb).abs, (pp - c).abs
        pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? bb : c)
        b[i] = (b[i] + pred) & 255
      end
    else raise "bad PNG filter #{ft}"
    end
    prev = b.pack("C*")
    w.times do |x|
      o = x * bpp
      a = bpp == 4 ? b[o + 3] : 255
      px[y * w + x] = (a << 24) | (b[o] << 16) | (b[o + 1] << 8) | b[o + 2]
    end
  end
  [w, h, px]
end

# ---------- driver -----------------------------------------------------------
inp, out = ARGV[0], ARGV[1]
abort "usage: dds_ai_upscale.rb <in.dds> <out.dds> [--exe PATH] [--model NAME]" unless inp && out
i = ARGV.index("--exe");   exe   = i ? ARGV[i + 1] : nil
i = ARGV.index("--model"); model = i ? ARGV[i + 1] : "realesrgan-x4plus"
abort "need --exe pointing at realesrgan-ncnn-vulkan.exe" unless exe && File.exist?(exe)

d = File.binread(inp)
abort "not DDS" unless d[0, 4] == "DDS "
hh = d[4, 124].unpack("V31")
w0, h0, mips = hh[3], hh[2], hh[6]
fourcc = d[84, 4]
abort "DXT1/DXT5 only, got #{fourcc.inspect}" unless %w[DXT1 DXT5].include?(fourcc)
dxt5 = fourcc == "DXT5"

base = dxt5 ? dxt5_decode(d, 128, w0, h0) : dxt1_decode(d, 128, w0, h0)
tmp  = File.join(Dir.tmpdir, "ai_#{Process.pid}")
png_write("#{tmp}_in.png", w0, h0, base, alpha: false)

cmd = [exe, "-i", "#{tmp}_in.png", "-o", "#{tmp}_out.png", "-n", model, "-s", "4"]
puts "  #{File.basename(inp)}  #{w0}x#{h0} #{fourcc}  ->  ESRGAN x4 (#{model})"
system(*cmd, out: File::NULL, err: File::NULL) or abort "upscaler failed"

uw, uh, up = png_read("#{tmp}_out.png")
abort "expected #{w0*4}x#{h0*4}, got #{uw}x#{uh}" unless uw == w0 * 4 && uh == h0 * 4

nw, nh = w0 * 2, h0 * 2
rgb = resize(up, uw, uh, nw, nh)

if dxt5
  # carry the ORIGINAL alpha separately - the model never saw it
  a2 = resize(base.map { |v| ((v >> 24) & 255) * 0x010101 }, w0, h0, nw, nh)
  rgb = rgb.each_index.map { |k| ((a2[k] & 255) << 24) | (rgb[k] & 0x00FFFFFF) }
end

levels = []
cur, cw, ch = rgb, nw, nh
loop do
  levels << [cur, cw, ch]
  break if cw == 1 && ch == 1
  ncw, nch = [cw / 2, 1].max, [ch / 2, 1].max
  cur = resize(cur, cw, ch, ncw, nch)
  cw, ch = ncw, nch
end
levels = levels.first(mips + 1)
enc  = ->(px, lw, lh) { dxt5 ? dxt5_encode(px, lw, lh) : dxt1_encode(px, lw, lh) }
body = levels.map { |px, lw, lh| enc.(px, lw, lh) }.join
data = dds_header(nw, nh, levels.size, enc.(levels[0][0], nw, nh).bytesize, fourcc) + body
File.binwrite(out, data)
File.delete("#{tmp}_in.png", "#{tmp}_out.png") rescue nil
puts "  -> #{File.basename(out)}  #{nw}x#{nh} #{fourcc}, #{levels.size} mips, #{data.bytesize} bytes"
