# hipoly_build.rb - build the whole high-poly unit corpus in one pass.
#
# The hi-poly pack was previously produced ad hoc, with the rules living only in
# a roadmap. This encodes them, so the result is reproducible instead of
# remembered.
#
#   ruby hipoly_build.rb                    # extract + subdivide + stage
#   ruby hipoly_build.rb --only euro_line   # just matching units (for a test run)
#   ruby hipoly_build.rb --steps 1          # subdivision steps (default 1)
#   ruby hipoly_build.rb --list             # show what WOULD be processed
#   ruby hipoly_build.rb --verify           # reference check only, ~10s
#   ruby hipoly_build.rb --no-verify        # skip the gate (not advised)
#
# THREE RULES, ENFORCED HERE
#
#  1. EXCLUDE zz_* PACKS when resolving which pack owns a path. They are OUR
#     output; reading them back re-subdivides already-subdivided meshes and
#     compounds the error silently. The check that proves you got this right is
#     --verify, below: euro_line_infantry must regenerate byte-identical to a
#     hash stored IN THIS FILE. It deliberately does not compare against a
#     built zz_hipoly.pack - a release ships no generated packs, and a check
#     that needs the artefact it is checking is not a check.
#
#  2. A UNIT IS ALL-OR-NOTHING ACROSS ITS LODs. If lod1 fails and lod2 succeeds,
#     shipping the lod2 alone gives that unit a VANILLA close-up and a DETAILED
#     mid-range - detail increasing with distance, the inverse of a LOD chain,
#     and it reads in game as a backwards pop at the 200-unit boundary.
#
#  3. subdiv_vwm needs a global pose and refuses meshes whose bones it cannot
#     place (all 72 mounts). subdiv_local works in shared bone frames with no
#     pose, so it is the fallback - not the default, because the posed tool's
#     object-space check is the stricter of the two.
require "fileutils"
require "digest"
require_relative "../../empire_paths"

TOOLS = __dir__

# euro_line_infantry regenerated from VANILLA packs only, steps=1. The reference
# lives HERE so the check works on a clean checkout with no generated packs
# present anywhere on the machine.
REFERENCE = {
  1 => [1_928_610, "7a7a4300892a33027289e600309a4e927104e022be376081b4f402bb07fb3b39"],
  2 => [1_189_306, "873a454b28621f7815860dc35dfa960f6214b3cc3a8393cd48025b8437173f36"]
}.freeze
REFERENCE_UNIT = "euro_line_infantry".freeze

def opt(name, default = nil)
  i = ARGV.index("--#{name}")
  i && ARGV[i + 1] && !ARGV[i + 1].start_with?("--") ? ARGV[i + 1] : default
end

verify  = ARGV.include?("--verify")
only    = verify ? REFERENCE_UNIT : opt("only")
steps   = verify ? 1 : (opt("steps", "1")).to_i
listing = ARGV.include?("--list")

# Staging is REPO-relative. Deriving it from EMPIRE.game assumed the toolkit is
# unzipped inside the Steam install; a release can sit anywhere.
STAGE = File.expand_path(verify ? "../../staged/_verify" : "../../staged/hipoly_auto", __dir__)

# A full run that silently produces WRONG geometry is the documented disaster: a
# relative data path once made subdiv_vwm fail so the fallback took over, with no
# error and a 1,841,482-byte mesh instead of 1,928,610. Gate the corpus on the
# reference check rather than trusting the run.
if !verify && !listing && !ARGV.include?("--no-verify")
  puts "reference check (#{REFERENCE_UNIT}) before the full run..."
  abort "reference check FAILED - not building the corpus." unless system("ruby", __FILE__, "--verify")
  puts
end

# ---- 1. index every vanilla pack, LATER pack wins ------------------------
def pack_index(path)
  f = File.open(path, "rb")
  hdr = f.read(64)
  return {} unless hdr && hdr[0, 4] == "PFH0"
  _t, _dc, dl, fc, il = hdr[4, 20].unpack("V5")
  f.seek(24 + dl)
  entries = []
  fc.times do
    sz = f.read(4).unpack1("V")
    s = +""
    while (c = f.read(1)) && c != "\0"
      s << c
    end
    entries << [s.downcase, sz]
  end
  off = 24 + dl + il
  out = {}
  entries.each { |name, sz| out[name] = [path, off, sz]; off += sz }
  f.close
  out
end

packs = Dir.glob(File.join(EMPIRE.data, "*.pack")).sort
vanilla = packs.reject { |p| File.basename(p).downcase.start_with?("zz_") }
if vanilla.size != packs.size
  puts "ignoring #{packs.size - vanilla.size} zz_* pack(s) - reading our own output would compound subdivision"
end

index = {}
vanilla.each { |p| index.merge!(pack_index(p)) }   # later pack wins, as the game does
puts "indexed #{index.size} files from #{vanilla.size} vanilla packs"

# ---- 2. pair up lod1/lod2 per unit ---------------------------------------
units = Hash.new { |h, k| h[k] = {} }
index.each_key do |name|
  next unless name =~ %r{\Aunitmodels[\\/](.+)_lod([12])\.variant_weighted_mesh\z}
  units[$1][$2.to_i] = name
end
units.reject! { |_, v| v.size != 2 }               # need BOTH lods (rule 2)
units.select! { |u, _| u.include?(only) } if only
puts "#{units.size} unit(s) with a complete lod1+lod2 pair#{only ? " matching '#{only}'" : ""}"

if listing
  units.keys.sort.first(40).each { |u| puts "  #{u}" }
  puts "  ... (#{units.size} total)" if units.size > 40
  exit
end

# ---- 3. extract, subdivide, stage ---------------------------------------
FileUtils.rm_rf(STAGE)
FileUtils.mkdir_p(File.join(STAGE, "unitmodels"))
tmp = File.join(STAGE, "_tmp")
FileUtils.mkdir_p(tmp)

ok = 0
failed = []
units.keys.sort.each_with_index do |unit, i|
  outs = {}
  broke = nil
  [1, 2].each do |lod|
    name = units[unit][lod]
    pack, off, sz = index[name]
    raw = File.open(pack, "rb") { |f| f.seek(off); f.read(sz) }
    src = File.join(tmp, "#{unit}_lod#{lod}.vwm")
    dst = File.join(tmp, "#{unit}_lod#{lod}.out.vwm")
    File.binwrite(src, raw)

    # posed tool first (stricter check), local as the documented fallback
    system("ruby", File.join(TOOLS, "subdiv_vwm.rb"), src, dst, "--steps", steps.to_s,
           out: File::NULL, err: File::NULL)
    unless File.exist?(dst) && File.size(dst) > 0
      system("ruby", File.join(TOOLS, "subdiv_local.rb"), src, dst, "--steps", steps.to_s,
             out: File::NULL, err: File::NULL)
    end
    if File.exist?(dst) && File.size(dst) > 0
      outs[lod] = [dst, name]
    else
      broke = lod
      break
    end
  end

  if broke
    failed << [unit, broke]
    next                                            # rule 2: drop BOTH lods
  end
  outs.each_value do |dst, name|
    target = File.join(STAGE, name.tr("\\", "/"))
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(dst, target)
  end
  ok += 1
  print "\r  #{i + 1}/#{units.size}  ok=#{ok} failed=#{failed.size}   "
end
puts

FileUtils.rm_rf(tmp)

if verify
  bad = []
  REFERENCE.each do |lod, (want_size, want_hash)|
    f = File.join(STAGE, "unitmodels", "#{REFERENCE_UNIT}_lod#{lod}.variant_weighted_mesh")
    unless File.exist?(f)
      bad << "lod#{lod}: NOT PRODUCED"
      next
    end
    got_size = File.size(f)
    got_hash = Digest::SHA256.file(f).hexdigest
    if got_size == want_size && got_hash == want_hash
      puts "  lod#{lod}  OK   #{got_size} bytes"
    else
      bad << "lod#{lod}: got #{got_size} bytes / #{got_hash[0, 16]}, want #{want_size} / #{want_hash[0, 16]}"
    end
  end
  FileUtils.rm_rf(STAGE)
  if bad.empty?
    puts "reference check PASSED - reproduces the known-good mesh from vanilla packs alone"
    exit 0
  end
  warn "reference check FAILED:"
  bad.each { |b| warn "  #{b}" }
  warn ""
  warn "Most likely causes, in order:"
  warn "  1. a zz_* pack is being read as input (it should be excluded above)"
  warn "  2. subdiv_vwm.rb failed and subdiv_local.rb silently took over - check"
  warn "     that vwm_json.rb can still find docs/warscape_pose.json"
  warn "  3. a subdivision tool changed behaviour"
  exit 1
end

mb = Dir.glob(File.join(STAGE, "**/*")).select { |f| File.file?(f) }.sum { |f| File.size(f) } / 1024.0 / 1024.0
puts
puts "staged  : #{STAGE}"
puts "units   : #{ok} complete, #{failed.size} dropped"
puts "size    : #{mb.round(1)} MB"
unless failed.empty?
  puts "dropped (BOTH lods, rule 2):"
  failed.first(12).each { |u, lod| puts "   #{u} (lod#{lod} refused)" }
  puts "   ... #{failed.size - 12} more" if failed.size > 12
end
puts
puts "next: empire.ps1 pack #{STAGE} zz_hipoly.pack -Deploy"
