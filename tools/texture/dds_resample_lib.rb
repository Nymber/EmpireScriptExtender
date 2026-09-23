# dds_resample_lib.rb - DXT1 / DXT5 codecs, alpha-aware Lanczos, PSNR and the
# DDS header writer. Split out so dds_resample.rb and dds_ai_upscale.rb share
# ONE implementation; duplicating a codec is how two tools quietly disagree.
#
# dds_resample.rb - decode a DXT1 .dds, resample it, and RE-ENCODE to DXT1
# with a full mip chain.
#
# WHY THIS IS THE MISSING HALF
#   `dds_upscale2x.rb` doubles a texture exactly, in block space, without ever
#   decoding - which is perfect for proving the engine accepts 2048 but adds
#   literally zero detail. Any route to REAL detail (an AI upscaler, a repaint,
#   a sharpen) produces RGB pixels, and those pixels have to get back into a
#   DXT1 .dds. Nothing in the toolchain could do that. This can.
#
#   So the pipeline becomes:
#       .dds --decode--> RGB --[whatever improves it]--> RGB --encode--> .dds
#   and the middle step is swappable.
#
# THE ENCODER
#   Per 4x4 block: find the principal colour axis by power iteration, SEED the
#   endpoints from the two extreme PIXELS along it, then try refinement passes
#   and KEEP WHICHEVER CANDIDATE MEASURES BEST in quantised 565 space.
#
#   Both of those were worth real dB. Seeding from a synthesised mean+axis*t
#   point, and accepting the refinement unconditionally, together scored
#   36.45 dB on a re-encode. Seeding from real pixels and keeping the best
#   candidate scores 48.81 dB on the same texture - a re-encode of DXT1 data
#   should be near-lossless, because each block only holds the four colours
#   its own endpoints generate, so anything far below that is the encoder
#   failing to rediscover endpoints that are sitting right there.
#
#   c0 > c1 is forced so every block stays in 4-colour mode. The 3-colour mode
#   exists for punch-through alpha, and silently dropping into it changes which
#   palette entry index 3 means - a whole block goes black rather than dark.
#
# QUALITY IS MEASURED, NOT ASSUMED
#   `check` re-encodes a texture at its own size and reports PSNR against the
#   original decode. Encoding to DXT1 is lossy, so a re-encode of already-DXT1
#   data loses a second generation; the number says how much. Anything above
#   ~40 dB is indistinguishable in practice.
#
# DXT5 / BC3 IS SUPPORTED TOO, and it is the format that matters most here:
# 63% of the game's 6,607 textures are DXT5, including every unit NORMAL and
# GLOSS map, and normals carry more perceived surface detail than diffuse.
# Measured re-encode quality: normal map 50.64 dB RGB / 48.16 dB alpha,
# gloss map 39.29 / 52.65, diffuse (DXT1) 48.81.
#
# TWO THINGS THAT WILL BITE WHOEVER EDITS THIS FILE WITH A SCRIPT:
#   * `String#sub(pattern, replacement)` treats `\0` in the REPLACEMENT as a
#     backreference to the whole match. Inserting code containing "\0" * 6
#     silently produced `"# ---------- resampling ---" * 6` - a 164-byte
#     "alpha block" - and scored 6.18 dB. Use the block form, `sub { ... }`.
#   * BC3's colour block is ALWAYS 4-colour. The DXT1 rule where c0 <= c1
#     selects a 3-colour + punch-through palette does not apply, and using
#     it decodes a third of every palette wrongly.
# Usage
#   ruby dds_resample.rb up2x  <in.dds> <out.dds>   # Lanczos to 2x, re-encode
#   ruby dds_resample.rb check <in.dds>             # PSNR of one encode round
#
# NOTE: `up2x` RESAMPLES; it does not invent detail. It produces a smoother
# 2048 than nearest-neighbour but carries exactly the information the 1024
# already had. For real detail the middle step has to be something else.

# ---------- DXT1 decode ------------------------------------------------------
def dxt1_decode(data, off, w, h)
  bw, bh = [(w + 3) / 4, 1].max, [(h + 3) / 4, 1].max
  px = Array.new(w * h, 0)
  bh.times do |by|
    bw.times do |bx|
      o = off + (by * bw + bx) * 8
      c0, c1 = data[o, 2].unpack1("v"), data[o + 2, 2].unpack1("v")
      rows = data[o + 4, 4].bytes
      to = ->(c) { [((c >> 11) & 31) * 255 / 31, ((c >> 5) & 63) * 255 / 63, (c & 31) * 255 / 31] }
      a, b = to.(c0), to.(c1)
      pal = if c0 > c1
              [a, b, (0..2).map { |i| (2 * a[i] + b[i]) / 3 }, (0..2).map { |i| (a[i] + 2 * b[i]) / 3 }]
            else
              [a, b, (0..2).map { |i| (a[i] + b[i]) / 2 }, [0, 0, 0]]
            end
      4.times do |y|
        4.times do |x|
          py, pxx = by * 4 + y, bx * 4 + x
          next if py >= h || pxx >= w
          c = pal[(rows[y] >> (2 * x)) & 3]
          px[py * w + pxx] = (c[0] << 16) | (c[1] << 8) | c[2]
        end
      end
    end
  end
  px
end

# ---------- DXT1 encode ------------------------------------------------------
def q565(r, g, b) = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
def d565(c) = [((c >> 11) & 31) * 255 / 31, ((c >> 5) & 63) * 255 / 63, (c & 31) * 255 / 31]

def encode_block(cols)
  n = cols.size
  mean = [0, 0, 0]
  cols.each { |c| 3.times { |i| mean[i] += c[i] } }
  mean.map! { |v| v.to_f / n }

  # principal axis by power iteration on the 3x3 covariance
  cov = Array.new(9, 0.0)
  cols.each do |c|
    d = [c[0] - mean[0], c[1] - mean[1], c[2] - mean[2]]
    3.times { |i| 3.times { |j| cov[i * 3 + j] += d[i] * d[j] } }
  end
  ax = [1.0, 1.0, 1.0]
  8.times do
    nx = (0..2).map { |i| (0..2).sum { |j| cov[i * 3 + j] * ax[j] } }
    m = Math.sqrt(nx.sum { |v| v * v })
    break if m < 1e-9
    ax = nx.map { |v| v / m }
  end

  # Seed from the ACTUAL extreme PIXELS along the axis, not from a point
  # reconstructed as mean + axis*t. Reconstructing costs ~4 dB for nothing: the
  # input to a re-encode is itself DXT1 output, so each block holds at most four
  # distinct colours and the original endpoints are literally present as pixel
  # values. Taking real pixels finds them; synthesising a point does not.
  proj = cols.map { |c| (0..2).sum { |i| (c[i] - mean[i]) * ax[i] } }
  e0 = cols[proj.each_with_index.max_by { |v, _| v }[1]].dup
  e1 = cols[proj.each_with_index.min_by { |v, _| v }[1]].dup

  # Refinement is only ACCEPTED IF IT MEASURABLY HELPS.
  # Re-fitting each endpoint to the mean of the pixels nearest it drags both
  # endpoints inward - the mean of {c0, (2c0+c1)/3} is not c0 - so on already
  # quantised input it destroys an exact seed. Applied blindly it cost ~0 dB
  # overall while wrecking flat and two-tone blocks. Keep the best candidate by
  # measured error instead of trusting the iteration.
  best0, best1 = e0, e1
  besterr = block_error(cols, e0, e1)
  r0, r1 = e0, e1
  2.times do
    pal = palette(r0, r1)
    g0 = []; g1 = []
    cols.each do |c|
      i = nearest(pal, c)
      (i == 0 || i == 2 ? g0 : g1) << c
    end
    r0 = avg(g0) if g0.any?
    r1 = avg(g1) if g1.any?
    e = block_error(cols, r0, r1)
    (besterr = e; best0, best1 = r0, r1) if e < besterr
  end
  e0, e1 = best0, best1

  c0, c1 = q565(*e0), q565(*e1)
  # force 4-colour mode; equal endpoints are fine (flat block) but must not
  # fall into the 3-colour branch, so nudge instead of swapping semantics
  if c0 < c1 then c0, c1 = c1, c0 end
  c1 -= 1 if c0 == c1 && c1 > 0
  pal = palette(d565(c0), d565(c1))
  rows = (0..3).map do |y|
    v = 0
    (0..3).each { |x| v |= nearest(pal, cols[y * 4 + x]) << (2 * x) }
    v
  end
  [c0, c1].pack("v2") + rows.pack("C4")
end

# error of a block under a candidate endpoint pair, measured in the QUANTISED
# 565 space the hardware will actually use - fitting in 888 and hoping is how
# an encoder scores well on paper and badly in game
def block_error(cols, e0, e1)
  a, b = d565(q565(*e0)), d565(q565(*e1))
  pal = palette(a, b)
  cols.sum { |c| p2 = pal[nearest(pal, c)]
    (p2[0]-c[0])**2 + (p2[1]-c[1])**2 + (p2[2]-c[2])**2 }
end

def palette(a, b)
  [a, b, (0..2).map { |i| (2 * a[i] + b[i]) / 3 }, (0..2).map { |i| (a[i] + 2 * b[i]) / 3 }]
end

def avg(g)
  (0..2).map { |i| (g.sum { |c| c[i] }.to_f / g.size).round.clamp(0, 255) }
end

def nearest(pal, c)
  best = 0; bd = 1 << 30
  pal.each_with_index do |p, i|
    d = (p[0] - c[0])**2 + (p[1] - c[1])**2 + (p[2] - c[2])**2
    (bd = d; best = i) if d < bd
  end
  best
end

def dxt1_encode(px, w, h)
  bw, bh = [(w + 3) / 4, 1].max, [(h + 3) / 4, 1].max
  out = String.new(capacity: bw * bh * 8)
  bh.times do |by|
    bw.times do |bx|
      cols = []
      4.times do |y|
        4.times do |x|
          sx = [bx * 4 + x, w - 1].min
          sy = [by * 4 + y, h - 1].min
          v = px[sy * w + sx]
          cols << [(v >> 16) & 255, (v >> 8) & 255, v & 255]
        end
      end
      out << encode_block(cols)
    end
  end
  out
end


# ---------- DXT5 / BC3 -------------------------------------------------------
# 16-byte block: 8 bytes alpha then 8 bytes colour.
#   alpha : [u8 a0][u8 a1][48 bits of 3-bit indices, little-endian]
#           a0 > a1  -> 8 interpolated values
#           a0 <= a1 -> 6 interpolated + explicit 0 and 255
#   colour: same layout as DXT1 but ALWAYS 4-colour. BC3 has no punch-through
#           mode, so the c0 <= c1 branch does not exist here and applying the
#           DXT1 rule would decode a third of the palette wrongly.
#
# The alpha channel is NOT decorative on this content: unit normal maps carry
# real data in it (endpoints measured at 104..217, 8-value mode in 99% of
# blocks), which is the DXT5nm-style packing. Treating alpha as opaque would
# silently flatten every normal map in the game.
def alpha_palette(a0, a1)
  if a0 > a1
    [a0, a1] + (1..6).map { |i| ((7 - i) * a0 + i * a1) / 7 }
  else
    [a0, a1] + (1..4).map { |i| ((5 - i) * a0 + i * a1) / 5 } + [0, 255]
  end
end

def dxt5_decode(data, off, w, h)
  bw, bh = [(w + 3) / 4, 1].max, [(h + 3) / 4, 1].max
  px = Array.new(w * h, 0)
  bh.times do |by|
    bw.times do |bx|
      o = off + (by * bw + bx) * 16
      a0, a1 = data[o].ord, data[o + 1].ord
      apal = alpha_palette(a0, a1)
      abits = data[o + 2, 6].bytes
      lo = abits[0] | (abits[1] << 8) | (abits[2] << 16)
      hi = abits[3] | (abits[4] << 8) | (abits[5] << 16)
      c0, c1 = data[o + 8, 2].unpack1("v"), data[o + 10, 2].unpack1("v")
      rows = data[o + 12, 4].bytes
      to = ->(c) { [((c >> 11) & 31) * 255 / 31, ((c >> 5) & 63) * 255 / 63, (c & 31) * 255 / 31] }
      a, b = to.(c0), to.(c1)
      pal = [a, b, (0..2).map { |i| (2 * a[i] + b[i]) / 3 }, (0..2).map { |i| (a[i] + 2 * b[i]) / 3 }]
      4.times do |y|
        4.times do |x|
          py, pxx = by * 4 + y, bx * 4 + x
          next if py >= h || pxx >= w
          k = y * 4 + x
          ai = k < 8 ? (lo >> (3 * k)) & 7 : (hi >> (3 * (k - 8))) & 7
          c = pal[(rows[y] >> (2 * x)) & 3]
          px[py * w + pxx] = (apal[ai] << 24) | (c[0] << 16) | (c[1] << 8) | c[2]
        end
      end
    end
  end
  px
end

def encode_alpha_block(vals)
  a0, a1 = vals.max, vals.min
  if a0 == a1
    return [a0, a1].pack("C2") + ("\x00" * 6)
  end
  pal = alpha_palette(a0, a1)
  bits = 0
  vals.each_with_index do |v, k|
    best = 0; bd = 1 << 30
    pal.each_with_index { |p, i| dd = (p - v).abs; (bd = dd; best = i) if dd < bd }
    bits |= best << (3 * k)
  end
  [a0, a1].pack("C2") + (0...6).map { |i| (bits >> (8 * i)) & 255 }.pack("C6")
end

def encode_colour_block_bc3(cols)
  # identical endpoint search to DXT1, minus the 4-colour-mode forcing, which
  # BC3 does not need
  blk = encode_block(cols)
  c0, c1 = blk[0, 2].unpack1("v"), blk[2, 2].unpack1("v")
  blk
end

def dxt5_encode(px, w, h)
  bw, bh = [(w + 3) / 4, 1].max, [(h + 3) / 4, 1].max
  out = String.new(capacity: bw * bh * 16)
  bh.times do |by|
    bw.times do |bx|
      cols = []; alphas = []
      4.times do |y|
        4.times do |x|
          sx = [bx * 4 + x, w - 1].min
          sy = [by * 4 + y, h - 1].min
          v = px[sy * w + sx]
          alphas << ((v >> 24) & 255)
          cols << [(v >> 16) & 255, (v >> 8) & 255, v & 255]
        end
      end
      out << encode_alpha_block(alphas) << encode_colour_block_bc3(cols)
    end
  end
  out
end

# ---------- resampling -------------------------------------------------------
def lanczos_kernel(x, a = 3)
  return 1.0 if x.abs < 1e-8
  return 0.0 if x.abs >= a
  px = Math::PI * x
  a * Math.sin(px) * Math.sin(px / a) / (px * px)
end

def resize(px, w, h, nw, nh)
  # separable Lanczos-3
  tmp = Array.new(nw * h, 0)
  sx = w.to_f / nw
  nw.times do |x|
    cx = (x + 0.5) * sx - 0.5
    i0 = (cx - 3).ceil; i1 = (cx + 3).floor
    ws = (i0..i1).map { |i| lanczos_kernel(cx - i) }
    tot = ws.sum
    h.times do |y|
      r = g = b = a = 0.0
      (i0..i1).each_with_index do |i, k|
        v = px[y * w + i.clamp(0, w - 1)]
        wk = ws[k]
        a += ((v >> 24) & 255) * wk; r += ((v >> 16) & 255) * wk
        g += ((v >> 8) & 255) * wk;  b += (v & 255) * wk
      end
      tmp[y * nw + x] = ((a / tot).round.clamp(0, 255) << 24) | ((r / tot).round.clamp(0, 255) << 16) |
                        ((g / tot).round.clamp(0, 255) << 8) | (b / tot).round.clamp(0, 255)
    end
  end
  out = Array.new(nw * nh, 0)
  sy = h.to_f / nh
  nh.times do |y|
    cy = (y + 0.5) * sy - 0.5
    j0 = (cy - 3).ceil; j1 = (cy + 3).floor
    ws = (j0..j1).map { |j| lanczos_kernel(cy - j) }
    tot = ws.sum
    nw.times do |x|
      r = g = b = a = 0.0
      (j0..j1).each_with_index do |j, k|
        v = tmp[j.clamp(0, h - 1) * nw + x]
        wk = ws[k]
        a += ((v >> 24) & 255) * wk; r += ((v >> 16) & 255) * wk
        g += ((v >> 8) & 255) * wk;  b += (v & 255) * wk
      end
      out[y * nw + x] = ((a / tot).round.clamp(0, 255) << 24) | ((r / tot).round.clamp(0, 255) << 16) |
                        ((g / tot).round.clamp(0, 255) << 8) | (b / tot).round.clamp(0, 255)
    end
  end
  out
end

def psnr(a, b)
  se = 0.0
  a.each_index do |i|
    3.times { |s| d = ((a[i] >> (8 * s)) & 255) - ((b[i] >> (8 * s)) & 255); se += d * d }
  end
  mse = se / (a.size * 3)
  mse.zero? ? Float::INFINITY : 10 * Math.log10(255.0 * 255.0 / mse)
end

def dds_header(w, h, mips, top, fourcc = "DXT1")
  hdr = "DDS ".b + "\0" * 124
  hdr[4, 4] = [124].pack("V"); hdr[8, 4] = [0x0002100F].pack("V")
  hdr[12, 4] = [h].pack("V"); hdr[16, 4] = [w].pack("V")
  hdr[20, 4] = [top].pack("V"); hdr[28, 4] = [mips].pack("V")
  hdr[76, 4] = [32].pack("V"); hdr[80, 4] = [0x4].pack("V"); hdr[84, 4] = fourcc
  hdr[108, 4] = [0x401008].pack("V")
  hdr
end

