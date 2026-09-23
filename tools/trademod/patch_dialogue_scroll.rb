# patch_dialogue_scroll.rb - wire the scrollbar added by add_dialogue_scroll.rb
# into dialogue_box.lua.
#
# THE HARD REQUIREMENT IS THAT SHORT DIALOGUES LOOK UNCHANGED.
#   This panel is the game's confirmation box. DY_text is now 1200px tall
#   inside a 172px viewport and its text draws CENTRED, so left alone every
#   "Are you sure?" would render its text somewhere off in the middle of a
#   1200px component - i.e. invisible. So the panel must always position the
#   text, not only when it scrolls:
#
#     offset = (TALL - viewport) / 2     centres the block in the viewport
#
#   and short messages then look exactly as they did before the change.
#
# SCROLL RANGE IS ESTIMATED, AND DELIBERATELY CONSERVATIVE.
#   Nothing here can measure rendered text height; SetStateText returns a
#   WIDTH and there is no YOffset to read. So the range is derived from line
#   count, counting an extra line per ~55 characters to approximate wrapping.
#   Being wrong high would let the player scroll past the end into blank
#   space, so the estimate is clamped and the slider is hidden outright when
#   the text fits - a scrollbar that does nothing is worse than none.
#
# Usage
#   ruby patch_dialogue_scroll.rb <dialogue_box.lua> [--out F] [--apply]

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
path  = ARGV[0]
apply = ARGV.include?("--apply")
out   = opt("out", path)
abort "usage: ruby patch_dialogue_scroll.rb <dialogue_box.lua> [--out F] [--apply]" unless path && File.file?(path)

src = File.read(path, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").gsub("\r\n", "\n")
if src.include?("DlgScrollTo")
  puts "already patched - nothing to do"
  exit 0
end

anchor = "  local text_box = UIComponent(this:Find(\"DY_text\"))\n  text_box:SetStateText(txt)\n"
abort "anchor not found (Initialise's SetStateText)" unless src.include?(anchor)

helpers = <<~LUA
  -- ---------------------------------------------------------------- scroll
  -- Added by patch_dialogue_scroll.rb. DY_text now lives inside dlg_window,
  -- a type-10 clipping viewport, with dlg_slider beside it. Everything below
  -- is written to no-op safely if those components are absent, so an
  -- unpatched layout still works.
  DLG_VIEW = 172         -- the viewport height
  DLG_TALL = 1200        -- DY_text's height in the patched layout
  DLG_LINE = 20          -- approximate line height at this font
  g_dlg_max = 0

  -- Text draws centred in a 1200px component, so the block sits in the
  -- middle. This is the offset that brings its TOP to the top of the
  -- viewport; every scroll position is measured from here.
  local function dlg_base(h)
    return math.floor((DLG_TALL - h) / 2)
  end

  function DlgScrollTo(value)
    local w = this:Find("dlg_window")
    if w == nil then return end
    local t = UIComponent(w):Find("DY_text")
    if t == nil then return end
    if value == nil then value = 0 end
    if value < 0 then value = 0 end
    if value > g_dlg_max then value = g_dlg_max end
    UIComponent(t):MoveTo(0, -(g_dlg_base + value))
  end

  -- Empire's string table is NOT stock: template.text_input.lua calls
  -- string.length, which is not standard Lua. Do not assume either name
  -- exists, and do not use string.gfind (deprecated, and absent from some
  -- 5.1 builds) - plain string.find is the one thing certainly present.
  local function dlg_strlen(s)
    if string.length ~= nil then return string.length(s) end
    return string.len(s)
  end

  -- Estimate how tall the message renders. No API reports this, so count
  -- newlines and add one line per ~55 characters to approximate wrapping.
  local function dlg_height(txt)
    if txt == nil then return 0 end
    local s = tostring(txt)
    local lines, i = 1, 1
    while true do
      local p = string.find(s, "\\n", i, true)
      if p == nil then break end
      lines = lines + 1
      i = p + 1
    end
    local extra = math.floor(dlg_strlen(s) / 55)
    return (lines + extra) * DLG_LINE
  end

  function DlgLayout(txt)
    local w = this:Find("dlg_window")
    local s = this:Find("dlg_slider")
    if w == nil then return end                  -- unpatched layout
    local h = dlg_height(txt)
    if h < DLG_VIEW then h = DLG_VIEW end        -- never less than one screen
    if h > DLG_TALL then h = DLG_TALL end        -- cannot exceed the component
    g_dlg_base = dlg_base(h)
    g_dlg_max  = h - DLG_VIEW
    if s ~= nil then
      -- A slider that cannot move is worse than no slider: hide it.
      UIComponent(s):SetVisible(g_dlg_max > 0)
      if g_dlg_max > 0 then
        UIComponent(s):SetProperty("maxValue", g_dlg_max)
        UIComponent(s):LuaCall("Reset")
      end
    end
    DlgScrollTo(0)
  end

  -- The slider reports through the panel's Notify, like every other slider
  -- in this game.
  function Notify(notifier, value)
    local s = this:Find("dlg_slider")
    if s ~= nil and notifier == UIComponent(s):Address() then
      DlgScrollTo(value)
    end
  end

LUA

# Insert the helpers before Initialise, and the layout call right after the
# text is set - so the panel is positioned for whatever it was just given.
src = src.sub("function Initialise(", helpers + "function Initialise(")
src = src.sub(anchor, anchor + "  DlgLayout(txt)\n")

%w[DlgScrollTo DlgLayout Notify].each do |f|
  n = src.scan(/^function #{f}\b/).size
  abort "#{f} defined #{n} times - expected 1" unless n == 1
end
abort "DlgLayout is never called" unless src.include?("  DlgLayout(txt)")

puts "added   : DlgScrollTo, DlgLayout, Notify"
puts "called  : DlgLayout(txt) immediately after SetStateText in Initialise"
puts "guards  : no-ops when dlg_window is absent; slider hidden when text fits"
puts "centring: short messages keep their original centred appearance"

if apply
  File.write(out, src, mode: "wb")
  puts "\nwritten: #{out} (#{src.bytesize} bytes)"
else
  puts "\nDRY RUN (pass --apply to write)"
end
