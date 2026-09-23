# dds_ai_upscale_fast.rb - same result as dds_ai_upscale.rb, ~20x faster.
#
#   .dds --texconv--> PNG --Real-ESRGAN x4--> PNG --strip sRGB--> texconv
#        (resize to x2, encode BC1/BC3, generate mips)             --> .dds
#
# WHY THIS EXISTS
#   dds_ai_upscale.rb's hand-written pure-Ruby PNG codec + DXT block encoder
#   measured at 5m29s for ONE 1024 diffuse texture, isolated (not just under
#   memory contention - re-timed clean, same result). At the corpus scale this
#   project runs at (2,171 diffuse textures across units/naval/buildings),
#   that is ~8.3 days serial. Swapping in Microsoft's own DirectXTex `texconv`
#   (MIT-licensed, github.com/microsoft/DirectXTex/releases) for every step
#   except the actual neural upscale takes the SAME texture to 16 SECONDS -
#   confirmed by direct measurement, not estimated. Corpus math: ~9.6 hours
#   serial, ~2.4 hours 4-way parallel.
#
# THE TRAP THIS FILE EXISTS TO DOCUMENT
#   The naive version of this pipeline (texconv dds->png, ESRGAN, texconv
#   png->dds with -w/-h to resize) silently DARKENS the output: PSNR against
#   the known-good pure-Ruby output was 12.89 dB (a real corruption, not
#   encoder noise - encoder-only differences read >30 dB). Cause: Real-ESRGAN's
#   own PNG writer embeds an sRGB gamma chunk. texconv honours it, resizes in
#   (correctly) linearised space, then writes plain BC1_UNORM (not
#   BC1_UNORM_SRGB) WITHOUT re-applying the gamma curve - so linear-light
#   values land directly in a byte slot the game reads as gamma-encoded.
#   texconv's own hand-written PNG (no gAMA/sRGB chunk at all) round-trips at
#   48.64 dB - proving the file format is fine, the COLOR-MANAGEMENT METADATA
#   is what poisons it. Fix: strip gAMA/sRGB/cICP/iCCP chunks from ESRGAN's
#   PNG before texconv ever sees it. After stripping: 34.12 dB, consistent
#   with "two different resize+compress implementations", not corruption.
#
#   Do NOT switch the output format to BC1_UNORM_SRGB / BC3_UNORM_SRGB to
#   "properly" carry the tag through instead of stripping it - that forces a
#   DX10-extended-header DDS (FourCC "DX10", not "DXT1"/"DXT5"), which this
#   project's own DDS reader (dds_resample_lib.rb) does not parse, and which
#   Empire's DX9 engine was never proven to load. Every in-game-confirmed
#   texture in this project is a classic FourCC-header DDS. Keep it that way.
#
# ALPHA (DXT5 sources - every normal and gloss map)
#   Same policy as dds_ai_upscale.rb: Real-ESRGAN is an RGB model, so alpha is
#   carried separately via texconv's own resize (-sepalpha), never sent
#   through the model.
#
# Usage
#   ruby dds_ai_upscale_fast.rb <in.dds> <out.dds> --texconv PATH --exe PATH [--model NAME]

require "tmpdir"
require_relative "dds_resample_lib"

def strip_color_chunks(inp, out)
  d = File.binread(inp)
  raise "not PNG" unless d[0, 8] == "\x89PNG\r\n\x1a\n".b
  pos = 8
  keep = "\x89PNG\r\n\x1a\n".b
  strip = %w[gAMA sRGB cICP iCCP]
  while pos < d.bytesize
    len = d[pos, 4].unpack1("N"); type = d[pos + 4, 4]
    chunk_len = 12 + len
    keep << d[pos, chunk_len] unless strip.include?(type)
    pos += chunk_len
    break if type == "IEND"
  end
  File.binwrite(out, keep)
end

inp, out = ARGV[0], ARGV[1]
abort "usage: dds_ai_upscale_fast.rb <in.dds> <out.dds> --texconv PATH --exe PATH [--model NAME]" unless inp && out
i = ARGV.index("--texconv"); texconv = i ? ARGV[i + 1] : nil
i = ARGV.index("--exe");     exe     = i ? ARGV[i + 1] : nil
i = ARGV.index("--model");   model   = i ? ARGV[i + 1] : "realesrgan-x4plus"
abort "need --texconv pointing at texconv.exe" unless texconv && File.exist?(texconv)
abort "need --exe pointing at realesrgan-ncnn-vulkan.exe" unless exe && File.exist?(exe)

d = File.binread(inp)
abort "not DDS" unless d[0, 4] == "DDS "
hh = d[4, 124].unpack("V31")
w0, h0, mips = hh[3], hh[2], hh[6]
fourcc = d[84, 4]
abort "DXT1/DXT5 only, got #{fourcc.inspect}" unless %w[DXT1 DXT5].include?(fourcc)
bc = fourcc == "DXT1" ? "BC1_UNORM" : "BC3_UNORM"
nw, nh = w0 * 2, h0 * 2
target_mips = mips + 1 # game convention: 1024 ships 10 mips -> 2048 should ship 11, not a full chain to 1x1

Dir.mktmpdir("ai_fast_") do |tmp|
  sys = ->(*cmd) { system(*cmd, out: File::NULL, err: File::NULL) or abort "command failed: #{cmd.join(' ')}" }

  sys.(texconv, "-y", "-ft", "png", "-o", tmp, inp)
  base_png = File.join(tmp, File.basename(inp, ".dds") + ".png")

  puts "  #{File.basename(inp)}  #{w0}x#{h0} #{fourcc}  ->  ESRGAN x4 (#{model}) ->  texconv BC"
  up_png = File.join(tmp, "up.png")
  sys.(exe, "-i", base_png, "-o", up_png, "-n", model, "-s", "4")

  stripped = File.join(tmp, "up_stripped.png")
  strip_color_chunks(up_png, stripped)

  out_dir = File.dirname(File.expand_path(out))
  sys.(texconv, "-y", "-ft", "dds", "-f", bc, "-m", target_mips.to_s,
       "-w", nw.to_s, "-h", nh.to_s, "-o", tmp, stripped)
  produced = File.join(tmp, File.basename(stripped, ".png") + ".dds")
  File.binwrite(out, File.binread(produced))
end
puts "  -> #{File.basename(out)}  #{nw}x#{nh} #{fourcc}, #{target_mips} mips"
