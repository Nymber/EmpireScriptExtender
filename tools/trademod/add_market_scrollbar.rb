# add_market_scrollbar.rb - give the World Market a vertical scrollbar, cloned
# from the one Supply/Exports already use.
#
#
# WHAT IT CLONES
#   The `vslider` uientry inside `imports` - 496 lines, 16 ID fields, children
#   top/bottom/handle. It is self-contained, so the clone only needs its IDs
#   shifted (keeping internal image<->image_use links intact) and its track
#   resized for the shorter pane:
#
#     vslider state y size : 120 -> track
#     `bottom` child y     : 119 -> track - 1     (it sits at track-1)
#
#   The component keeps the name "vslider" because the panel script finds it as
#   UIComponent(UIComponent(this:Find("world market")):Find("vslider")).
#
# THIS IS HALF THE JOB. A slider with no script does nothing. The matching
# script edit (see docs/ADDING_A_COMMODITY.md and the Lua recompile pipeline)
# must add:
#   - market_slider = UIComponent(UIComponent(this:Find("world market")):Find("vslider"))
#   - market_slider:SetProperty("Notify", Address) in the init block
#   - a Notify branch dispatching to an UpdateMarketSlider(value)
#   - maxValue set from the number of wrapped rows in ShowTrade
# Shipping the slider alone is harmless (it renders and does nothing), which is
# why this step is separated - it can be verified on its own.
#
# Usage
#   ruby add_market_scrollbar.rb <government_screens.xml> [--x N] [--y N] [--track N] [--apply]

require "set"

path = ARGV[0]
def opt(f, d) i = ARGV.index(f); i ? ARGV[i + 1].to_i : d end
sx     = opt("--x", 544)
sy     = opt("--y", 16)     # just below the 16px top border
track  = opt("--track", 62) # pane 94 - 16 top - 16 bottom
apply  = ARGV.include?("--apply")
abort "usage: ruby add_market_scrollbar.rb <government_screens.xml> [--apply]" unless path && File.file?(path)

ID_SHIFT = 0x05000000

src   = File.read(path, mode: "rb")
lines = src.lines

# ---- the world market container -------------------------------------------
wi = lines.index { |l| l =~ /<s>world market<\/s><!-- title -->/ }
abort "no 'world market' component" unless wi
cs = nil
(wi...lines.size).each { |i| (cs = i; break) if lines[i] =~ /<children count="\d+">/ }
abort "world market has no <children>" unless cs

# already done?
ce = nil
depth = 0
(cs...lines.size).each do |i|
  depth += lines[i].scan(/<children[ >]/).size
  depth -= lines[i].scan(/<\/children>/).size
  if depth.zero? && i > cs
    ce = i
    break
  end
end
if ce && lines[cs..ce].join =~ /<s>vslider<\/s><!-- title -->/
  puts "the World Market already has a vslider - nothing to do"
  exit 0
end

# ---- find a vslider to clone (the first one, inside imports) --------------
ti = lines.index { |l| l =~ /<s>vslider<\/s><!-- title -->/ }
abort "no vslider anywhere to clone" unless ti
s = ti
s -= 1 while lines[s] !~ /<uientry>/
depth = 0
e = s
loop do
  depth += lines[e].scan(/<uientry>/).size
  depth -= lines[e].scan(/<\/uientry>/).size
  break if depth.zero? && e > s
  e += 1
end
block = lines[s..e].join
puts "cloning vslider from lines #{s + 1}..#{e + 1} (#{e - s + 1} lines)"

# ---- shift every ID clear of the existing ones -----------------------------
all_ids   = src.scan(/<u>(\d+)<\/u>/).flatten.map(&:to_i).to_set
block_ids = block.scan(/<u>(\d+)<\/u><!-- ID/).flatten.map(&:to_i)
bad = block_ids.map { |v| v + ID_SHIFT }.select { |v| all_ids.include?(v) }
abort "ID_SHIFT collides with #{bad.size} existing id(s)" unless bad.empty?
abort "ID_SHIFT overflows 32 bits" if block_ids.any? { |v| v + ID_SHIFT > 0xFFFFFFFF }

cl = block.dup
cl = cl.gsub(/<u>(\d+)<\/u>(<!-- ID[^>]*-->)/) { "<u>#{$1.to_i + ID_SHIFT}</u><!-- ID -->" }

# ---- reposition and resize --------------------------------------------------
# the vslider's own x/y are the two lines after its title
cl = cl.sub(/(<s>vslider<\/s><!-- title -->\s*\n\s*<i>)-?\d+(<\/i><!-- x offset -->\s*\n\s*<i>)-?\d+(<\/i><!-- y offset -->)/) { "#{$1}#{sx}#{$2}#{sy}#{$3}" }

# The track height is the vslider's own STATE y size. Finding it with a lazy
# regex from the title grabs an IMAGE's y size instead (the bar texture is
# 4x1), so walk the lines and take the first NewState after the title.
cll = cl.lines
vi = cll.index { |l| l =~ /<s>vslider<\/s><!-- title -->/ }
abort "clone lost its vslider title" unless vi
si = (vi...cll.size).find { |j| cll[j] =~ /<s>[^<]*<\/s><!-- title - NewState/ || cll[j] =~ /<s>NewState<\/s>/ }
abort "could not find the vslider's state" unless si
old_track = cll[si + 2][/<i>(\d+)<\/i>/, 1].to_i
abort "implausible track height #{old_track}" if old_track < 20

if old_track != track
  cll[si + 2] = cll[si + 2].sub(/<i>\d+<\/i>/, "<i>#{track}</i>")

  # RESIZING THE STATE IS NOT ENOUGH - the IMAGE_USES draw the thing. The bar
  # texture is a 4x1 tile stretched by its image_use to the track height; leave
  # that at the old value and the bar renders its ORIGINAL length, hanging out
  # of the pane and over the section below. (Same trap as a pane's 9-slice
  # frame: the state defines bounds, the image_uses define pixels.)
  ue_s = (si...cll.size).find { |j| cll[j] =~ /<image_uses count="\d+">/ }
  ue_e = ue_s && (ue_s...cll.size).find { |j| cll[j] =~ /<\/image_uses>/ }
  drawn = 0
  if ue_s && ue_e
    (ue_s..ue_e).each do |j|
      if cll[j] =~ /<u>#{old_track}<\/u><!-- y size -->/
        cll[j] = cll[j].sub(/<u>\d+<\/u>/, "<u>#{track}</u>")
        drawn += 1
      end
    end
  end
  if drawn.zero?
    STDERR.puts "WARNING: no image_use matched the old track height - the bar may render at the wrong length"
  else
    puts "slider bar     : #{drawn} image_use(s) resized #{old_track} -> #{track}"
  end

  # the `bottom` button sits at track - 1
  bi = cll.index { |l| l =~ /<s>bottom<\/s><!-- title -->/ }
  abort "clone lost its bottom button" unless bi
  oldb = cll[bi + 2][/<i>(-?\d+)<\/i>/, 1].to_i
  abort "bottom button at #{oldb}, expected #{old_track - 1}" unless oldb == old_track - 1
  cll[bi + 2] = cll[bi + 2].sub(/<i>-?\d+<\/i>/, "<i>#{track - 1}</i>")
end
cl = cll.join

# ---- also clone the display_window ----------------------------------------
# Supply and Exports each have BOTH a display_window and a vslider. Cloning the
# slider alone HUNG the Government tab, twice, with and without a script wiring
# it up - so the pair is likely not separable. This clones the sibling too.
added = 1
dw_clone = ""
unless ARGV.include?("--slider-only")
  di = lines.index { |l| l =~ /<s>display_window<\/s><!-- title -->/ }
  if di
    ds = di
    ds -= 1 while lines[ds] !~ /<uientry>/
    depth = 0
    de = ds
    loop do
      depth += lines[de].scan(/<uientry>/).size
      depth -= lines[de].scan(/<\/uientry>/).size
      break if depth.zero? && de > ds
      de += 1
    end
    dblock = lines[ds..de].join
    DW_SHIFT = 0x06000000
    dids = dblock.scan(/<u>(\d+)<\/u><!-- ID/).flatten.map(&:to_i)
    dbad = dids.map { |v| v + DW_SHIFT }.select { |v| all_ids.include?(v) }
    abort "display_window ID shift collides with #{dbad.size} id(s)" unless dbad.empty?
    dw_clone = dblock.gsub(/<u>(\d+)<\/u>(<!-- ID[^>]*-->)/) { "<u>#{$1.to_i + DW_SHIFT}</u><!-- ID -->" }
    # fill the pane's inner area, left of the slider
    dw_clone = dw_clone.sub(/(<s>display_window<\/s><!-- title -->\s*\n\s*<i>)-?\d+(<\/i><!-- x offset -->\s*\n\s*<i>)-?\d+(<\/i><!-- y offset -->)/) { "#{$1}11#{$2}16#{$3}" }

    # RESIZE IT. The clone inherits Supply's 129px height, which is taller than
    # this whole pane (94) - it renders visibly oversized. Match the slider's
    # track so the scrollable area and the scrollbar agree.
    dwl = dw_clone.lines
    dvi = dwl.index { |l| l =~ /<s>display_window<\/s><!-- title -->/ }
    dsi = dvi && (dvi...dwl.size).find { |j| dwl[j] =~ /<s>[^<]*<\/s><!-- title - NewState/ || dwl[j] =~ /<s>NewState<\/s>/ }
    if dsi
      oldw = dwl[dsi + 1][/<i>(\d+)<\/i>/, 1].to_i
      oldh = dwl[dsi + 2][/<i>(\d+)<\/i>/, 1].to_i
      dwl[dsi + 2] = dwl[dsi + 2].sub(/<i>\d+<\/i>/, "<i>#{track}</i>")
      dw_clone = dwl.join
      puts "cloning display_window from lines #{ds + 1}..#{de + 1} (#{de - ds + 1} lines) " \
           "-> x=11 y=16, #{oldw}x#{oldh} -> #{oldw}x#{track}"
    else
      STDERR.puts "WARNING: could not resize the display_window; it will render oversized"
      puts "cloning display_window from lines #{ds + 1}..#{de + 1} (#{de - ds + 1} lines) -> x=11 y=16"
    end
    added += 1
  else
    STDERR.puts "WARNING: no display_window found to clone"
  end
end

# ---- splice in as the last children and widen the count -------------------
abort "could not find the end of world market's children" unless ce
out = lines[0...ce].join + dw_clone + cl + lines[ce..-1].join
n = lines[cs][/<children count="(\d+)">/, 1].to_i
# Replace BY INDEX, not by text. `out.sub(lines[cs], ...)` patches the first
# line in the file with identical text, and `<children count="10">` at this
# indentation is NOT unique - it silently bumped some other container instead.
# The clone is spliced at `ce`, which is after `cs`, so the index still holds.
outl = out.lines
abort "line #{cs + 1} is no longer the children count" unless outl[cs] =~ /<children count="#{n}">/
outl[cs] = outl[cs].sub(/<children count="\d+">/, "<children count=\"#{n + added}\">")
out = outl.join

# ---- verify ----------------------------------------------------------------
chk = out.scan(/<s>vslider<\/s><!-- title -->/).size
puts "position       : x=#{sx} y=#{sy}, track #{old_track} -> #{track} (bottom at #{track - 1})"
puts "children count : #{n} -> #{n + added}"
puts "vsliders in file: #{lines.join.scan(/<s>vslider<\/s><!-- title -->/).size} -> #{chk}"
puts "size           : #{src.bytesize} -> #{out.bytesize} bytes"
puts
puts "NEXT: the script must wire it up - a slider with no Notify handler does nothing."
puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
File.write(path, out, mode: "wb") if apply
