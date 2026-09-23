# build_localisation.rb - produce the mod's text/localisation.loc and text/ui.loc.
#
# WHY THE MOD'S STRINGS WERE INVISIBLE
#   Empire.exe contains exactly TWO .loc path strings:
#       text/ui.loc            @ 0x0127EAE8
#       text/localisation.loc  @ 0x0128ADCC
#   There is no wildcard enumeration of text/*.loc. A pack shipping
#   `text/chain.loc` (or the older `text/rum.loc`) is therefore never read at
#   all, and every string in it is silently absent - blank building names,
#   blank descriptions, blank effect text, no error anywhere.
#
#   So the file has to BE one of those two.
#
# WHICH OF THE TWO
#   They are not interchangeable, and the split is not "UI vs not". Database
#   text (building names, descriptions, effects) is localisation.loc; text
#   baked into a .ui LAYOUT is ui.loc. A `<state>` carries BOTH a literal
#   string and a localisation id, and THE ID WINS - so the cloned Stock
#   Controls tab kept rendering "Trade" because its inherited id
#   `tab_title_NewState_Text_160050` resolves, in ui.loc, to "Trade".
#   Adding that key to localisation.loc does nothing; it has to go in ui.loc.
#
#   Pass `--which ui` for the ui.loc build. Note the FLAG BYTE differs:
#   localisation.loc entries use flag 0, ui.loc entries use flag 1. The flag
#   is carried per entry from the source, so a merge preserves it naturally.
#
# WHY THIS SHIPS A FULL COPY RATHER THAN JUST THE MOD'S ENTRIES
#   Vanilla ships that path in two packs - local_en.pack (32,700 entries) and
#   patch_en.pack (34,141) - and 32 keys exist only in the earlier one, so the
#   engine must merge rather than replace. But "must" is an inference, and if
#   it is wrong a 259-entry file would replace 34,000 strings and blank the
#   entire game's text. Emitting vanilla + the mod's entries is correct under
#   BOTH semantics, at the cost of ~6.5MB in the pack.
#
#   Later entries win, so the mod's own keys override any vanilla collision.
#
# Usage
#   ruby build_localisation.rb [--which localisation|ui] [--out F] [--mod F]

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
which = opt("which", "localisation")
abort "--which must be 'localisation' or 'ui'" unless %w[localisation ui].include?(which)
sfx = which == "ui" ? "_ui" : ""      # vanilla_local_en.loc / vanilla_local_en_ui.loc

# The mod's own entries live OUTSIDE staged/: everything under staged/ ships,
# and chain.loc would just be dead weight in the pack (nothing reads it).
chain_pack = File.join(ENV["TEMP"] || ENV["TMP"] || ".", "etw_chain_pack")
mod  = opt("mod",  File.join(chain_pack, "chain#{sfx}.loc"))
out  = opt("out",  File.join(chain_pack, "staged/text/#{which}.loc"))

def read_loc(path)
  d = File.binread(path)
  raise "#{path}: not a .loc" unless d[0, 2] == "\xFF\xFE".b && d[2, 3] == "LOC".b
  ver = d[6, 4].unpack1("l<")
  n   = d[10, 4].unpack1("l<")
  pos = 14
  rows = []
  n.times do
    kl = d[pos, 2].unpack1("v"); pos += 2
    k  = d[pos, kl * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += kl * 2
    vl = d[pos, 2].unpack1("v"); pos += 2
    v  = d[pos, vl * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += vl * 2
    f  = d[pos].unpack1("C"); pos += 1
    rows << [k, v, f]
  end
  raise "#{path}: #{d.bytesize - pos} trailing bytes - decode is wrong" unless pos == d.bytesize
  [ver, rows]
end

def write_loc(path, ver, rows)
  o = "\xFF\xFE".b + "LOC".b + "\x00".b + [ver].pack("l<") + [rows.size].pack("l<")
  rows.each do |k, v, f|
    ks = k.encode("UTF-16LE").b
    vs = v.encode("UTF-16LE").b
    o << [ks.bytesize / 2].pack("v") << ks
    o << [vs.bytesize / 2].pack("v") << vs
    o << [f].pack("C")
  end
  File.binwrite(path, o)
  o.bytesize
end

# Vanilla sources, earliest first so later packs override.
srcs = []
%w[local_en patch_en].each do |p|
  f = File.join(File.dirname(out), "..", "..", "vanilla_#{p}#{sfx}.loc")
  srcs << [p, f] if File.file?(f)
end
if srcs.size < 2
  root = File.expand_path(File.join(File.dirname(out), "..", ".."))
  abort <<~MSG
    Need the two vanilla #{which}.loc files extracted first, as
      #{root}/vanilla_local_en#{sfx}.loc
      #{root}/vanilla_patch_en#{sfx}.loc
    Extract with:
      packtool.ps1 -Pack local_en.pack -Find "#{which}.loc" -Extract -Out <dir>
      packtool.ps1 -Pack patch_en.pack -Find "#{which}.loc" -Extract -Out <dir>
  MSG
end

merged = {}
order  = []
version = 1
srcs.each do |name, f|
  v, rows = read_loc(f)
  version = v
  added = 0
  rows.each do |k, val, flag|
    order << k unless merged.key?(k)
    added += 1 unless merged.key?(k)
    merged[k] = [val, flag]
  end
  puts format("%-10s %6d entries (%d new)", name, rows.size, added)
end

_, modrows = read_loc(mod)
overrode = 0
modrows.each do |k, val, flag|
  overrode += 1 if merged.key?(k)
  order << k unless merged.key?(k)
  merged[k] = [val, flag]
end
puts format("%-10s %6d entries (%d overrode a vanilla key)", File.basename(mod), modrows.size, overrode)

rows = order.map { |k| [k, merged[k][0], merged[k][1]] }
n = write_loc(out, version, rows)

# Prove it round-trips before shipping it.
_, back = read_loc(out)
abort "re-read mismatch" unless back.size == rows.size
missing = modrows.reject { |k, _, _| back.any? { |bk, _, _| bk == k } }
abort "mod keys missing after write: #{missing.size}" unless missing.empty?
puts "\nwritten #{out}"
puts "#{rows.size} entries, #{n} bytes, round-trip verified, all #{modrows.size} mod keys present"
