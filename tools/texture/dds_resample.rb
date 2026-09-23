# dds_resample.rb - CLI over dds_resample_lib.rb
#   ruby dds_resample.rb up2x  <in.dds> <out.dds>   # Lanczos 2x, re-encode
#   ruby dds_resample.rb check <in.dds>             # PSNR of one encode round
#
# NOTE: up2x RESAMPLES; it does not invent detail, and measured as adding
# nothing in game. For real detail use dds_ai_upscale.rb.
require_relative "dds_resample_lib"

# ---------- driver -----------------------------------------------------------
mode, inp, out = ARGV
abort "usage: dds_resample.rb [up2x|check] <in.dds> [out.dds]" unless mode && inp

d = File.binread(inp)
abort "not DDS" unless d[0, 4] == "DDS "
hh = d[4, 124].unpack("V31")
w0, h0 = hh[3], hh[2]
FOURCC = d[84, 4]
abort "unsupported format #{FOURCC.inspect} (DXT1 and DXT5 only)" unless %w[DXT1 DXT5].include?(FOURCC)
IS_DXT5 = (FOURCC == "DXT5")
PAD = "\x00" * 128

def decode_any(data, off, w, h) = IS_DXT5 ? dxt5_decode(data, off, w, h) : dxt1_decode(data, off, w, h)
def encode_any(px, w, h)        = IS_DXT5 ? dxt5_encode(px, w, h)        : dxt1_encode(px, w, h)

base = decode_any(d, 128, w0, h0)

case mode
when "check"
  re   = encode_any(base, w0, h0)
  back = decode_any(PAD + re, 128, w0, h0)
  q = psnr(base, back)
  puts "#{File.basename(inp)}  #{w0}x#{h0} #{FOURCC}"
  puts format("  one %s encode round-trip: PSNR %.2f dB  %s",
              FOURCC, q, q > 40 ? "(indistinguishable)" : "(visible loss)")
  if IS_DXT5
    # Alpha has its OWN endpoints and its own index bits. A codec can score
    # well on RGB and still have destroyed it - and on a unit normal map the
    # alpha channel is where the X component lives, so that would be the whole
    # point lost. Score it separately.
    ae = base.each_index.sum { |k| (((base[k] >> 24) & 255) - ((back[k] >> 24) & 255))**2 }.to_f / base.size
    puts format("  ALPHA channel alone      : PSNR %.2f dB",
                ae.zero? ? Float::INFINITY : 10 * Math.log10(255.0 * 255 / ae))
  end
when "up2x"
  abort "need an output path" unless out
  nw, nh = w0 * 2, h0 * 2
  big = resize(base, w0, h0, nw, nh)
  levels = []
  cur, cw, ch = big, nw, nh
  loop do
    levels << [cur, cw, ch]
    break if cw == 1 && ch == 1
    ncw, nch = [cw / 2, 1].max, [ch / 2, 1].max
    cur = resize(cur, cw, ch, ncw, nch)
    cw, ch = ncw, nch
  end
  levels = levels.first(hh[6] + 1)
  body = levels.map { |px, lw, lh| encode_any(px, lw, lh) }.join
  top  = encode_any(levels[0][0], nw, nh).bytesize
  data = dds_header(nw, nh, levels.size, top, FOURCC) + body
  File.binwrite(out, data)
  puts "#{File.basename(inp)} #{w0}x#{h0} #{FOURCC} -> #{File.basename(out)} #{nw}x#{nh}, #{levels.size} mips, #{data.bytesize} bytes"
  chk = decode_any(data, 128, nw, nh)
  puts format("  encode fidelity at %d: PSNR %.2f dB vs the resampled source", nw, psnr(big, chk))
else
  abort "unknown command #{mode}"
end
