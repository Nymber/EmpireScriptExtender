# dds_upscale2x.rb - double a DXT1 .dds in each dimension, EXACTLY, with no
# re-encoding and no image library.
#
# WHY NOT JUST RESIZE IT
#   Resizing means decoding DXT1, resampling, and re-encoding - and DXT1
#   re-encoding is lossy and needs a compressor. For the question we are
#   actually asking ("does the engine accept a texture above 1024?") the pixels
#   do not need to change at all, only the dimensions.
#
# THE TRICK
#   A DXT1 block is [u16 color0][u16 color1][4 bytes of 16 two-bit indices]
#   covering 4x4 pixels. A 2x nearest-neighbour upscale maps each source block
#   onto 8x8 destination pixels = exactly 2x2 destination blocks, and each
#   destination block covers a 2x2 corner of the source block with every index
#   duplicated 2x2. The endpoints are unchanged, so the destination blocks
#   reuse color0/color1 VERBATIM and only the index bytes are rebuilt.
#   The result is bit-exact nearest-neighbour: no decode, no encode, no loss.
#
#   DXT1 also has a second meaning when color0 <= color1 (3 colours + 1-bit
#   alpha). Copying the endpoints untouched preserves that mode automatically,
#   which is why this is safer than any tint-based marker.
#
# THE MIP CHAIN IS FREE
#   A 2048 texture's mip 1 IS the original 1024 mip 0, mip 2 is the original
#   mip 1, and so on. So the output is [upscaled mip0] + [the entire original
#   file's mip chain], and every level below the top is byte-identical to
#   vanilla.
#
# Usage:  ruby dds_upscale2x.rb <in.dds> <out.dds>

def blocks_for(dim) = [(dim + 3) / 4, 1].max

src, dst = ARGV
abort "usage: dds_upscale2x.rb <in.dds> <out.dds>" unless dst

d = File.binread(src)
abort "not a DDS" unless d[0, 4] == "DDS "
hdr = d[0, 128].dup
h   = hdr[4, 124].unpack("V31")
height, width, mips = h[2], h[3], h[6]
fourcc = hdr[84, 4]
abort "only DXT1 is handled here, got #{fourcc.inspect}" unless fourcc == "DXT1"
abort "dimensions must be a multiple of 4" unless width % 4 == 0 && height % 4 == 0

# --- upscale mip 0 -----------------------------------------------------------
sbw, sbh = blocks_for(width), blocks_for(height)
mip0 = d[128, sbw * sbh * 8]
dbw, dbh = sbw * 2, sbh * 2
out = String.new(capacity: dbw * dbh * 8)

dbh.times do |dby|
  sby = dby / 2
  suby = (dby % 2) * 2
  dbw.times do |dbx|
    sbx = dbx / 2
    subx = (dbx % 2) * 2
    blk = mip0[(sby * sbw + sbx) * 8, 8]
    rows = blk[4, 4].bytes
    # read the source 2x2 corner, write it out with each index doubled
    newrows = (0..3).map do |dy|
      sy = suby + dy / 2
      row = rows[sy]
      v = 0
      (0..3).each do |dx|
        sx = subx + dx / 2
        idx = (row >> (2 * sx)) & 3
        v |= idx << (2 * dx)
      end
      v
    end
    out << blk[0, 4] << newrows.pack("C4")
  end
end

# --- header: double the dimensions, one more mip, new linear size ------------
hdr[12, 4] = [height * 2].pack("V")        # dwHeight
hdr[16, 4] = [width  * 2].pack("V")        # dwWidth
hdr[20, 4] = [out.bytesize].pack("V")      # dwPitchOrLinearSize = top mip size
hdr[28, 4] = [mips + 1].pack("V")          # dwMipMapCount

# --- the rest of the chain is the ORIGINAL file's mips, byte for byte --------
data = hdr + out + d[128..]
File.binwrite(dst, data)

expect = 128 + out.bytesize + (d.bytesize - 128)
puts "#{File.basename(src)}  #{width}x#{height} DXT1 #{mips} mips (#{d.bytesize} B)"
puts "  -> #{File.basename(dst)}  #{width*2}x#{height*2} DXT1 #{mips+1} mips (#{data.bytesize} B)"
abort "size mismatch" unless data.bytesize == expect
# prove the lower mips were not touched
abort "mip chain altered" unless data[(128 + out.bytesize)..] == d[128..]
puts "  mip 1..#{mips} are byte-identical to the source's mip 0..#{mips-1}"
