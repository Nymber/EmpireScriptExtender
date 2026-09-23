# Rescale Empire's LOD distance bands.
# Table: 5-byte header (01, then u32 row count), then 15 rows of
#   u16 keylen | UTF-16LE key "<numLods>_<lodIndex>" | float32 far-limit
# A value of 0 means "unbounded" (the last LOD) and must stay 0.
factor = (ARGV[0] || 3.0).to_f
src    = ARGV[1] || "lod_range.bin"
dst    = ARGV[2] || "lod_range_scaled.bin"

data = File.binread(src)
out  = data[0, 5].dup
pos  = 5
rows = []
while pos + 2 <= data.bytesize
  klen = data[pos, 2].unpack1("v")
  break if klen.nil? || klen == 0 || pos + 2 + klen*2 + 4 > data.bytesize
  key  = data[pos+2, klen*2].force_encoding("UTF-16LE").encode("UTF-8")
  val  = data[pos+2+klen*2, 4].unpack1("e")
  nval = (val.abs < 0.0001) ? 0.0 : val * factor
  rows << [key, val, nval]
  out << data[pos, 2 + klen*2]
  out << [nval].pack("e")
  pos += 2 + klen*2 + 4
end
abort("size changed: #{out.bytesize} vs #{data.bytesize}") unless out.bytesize == data.bytesize
File.binwrite(dst, out)
puts "factor x#{factor}  (#{rows.size} rows, #{out.bytesize} bytes - byte-exact)"
rows.each { |k,a,b| puts "  %-4s %8.1f -> %8.1f%s" % [k, a, b, (b == 0 ? "   (unbounded)" : "")] }
