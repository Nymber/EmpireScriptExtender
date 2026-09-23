# patch_market_labels.rb - two World Market fixes that share one anchor block.
#
# 1. THE GREEN ARROWS
#    ShowTrade hides each commodity's growth_arrow like this:
#
#      for k, v in pairs(trade_info.price_changes) do
#        UIComponent(UIComponent(window:Find(k)):Find("growth_arrow")):SetVisible(false)
#      end
#
#    but `price_changes` is built by a DIFFERENT set of inline native blocks
#    from `prices`, and ESE only clones the price ones. Measured live:
#      prices        = 23 keys
#      price_changes =  8 keys   (vanilla only)
#    so the 15 added commodities never got hidden and each showed a green
#    arrow. Vanilla only ever calls SetVisible(false) and never (true), so the
#    arrow is vestigial - iterating `prices` instead hides all 23 and matches
#    vanilla's appearance exactly. (Cloning the price_changes blocks too would
#    be strictly more work for an arrow that is never shown.)
#
# 2. THE MISSING DESCRIPTION
#    The World Market sets NO tooltip on any slot - not even vanilla ones, so
#    this is not a regression, it simply never existed. With 8 familiar goods
#    that was survivable; with 23, several of them manufactured, it is not.
#
#    There is no localisation API in the UI lua_State (no `effect.get_*`, no
#    `localisation` global), so the strings are baked in here, generated from
#    chain_manifest.txt and the shipped .loc so they cannot drift from the data.
#    Manufactured goods also get their recipe and what they feed into, which is
#    the part a player cannot discover anywhere else in the UI.
#
# Usage
#   ruby patch_market_labels.rb <government_screens.lua> [--manifest F]
#                               [--loc F] [--config F] [--apply]

require_relative "../../empire_paths"

path = ARGV[0]
apply = ARGV.include?("--apply")
def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
here     = File.dirname(File.expand_path(__FILE__))
manifest = opt("manifest", File.join(here, "chain_manifest.txt"))
# NOT under staged/ - the mod's own entries live outside it, because everything
# in staged ships and the engine only ever reads text/localisation.loc. Pointing
# at the old staged path silently yielded an EMPTY loc and every commodity
# tooltip fell back to its bare key ("coal" instead of "Coal").
locfile  = opt("loc",      File.join(ENV["TEMP"] || ENV["TMP"] || ".", "etw_chain_pack/chain.loc"))
config   = opt("config",   File.join(EMPIRE.game, "ese_commodities.txt"))
# The stockpile file chain_sim writes. The panel runs in the UI lua_State and
# chain_sim in the campaign one, so they cannot call each other - this file is
# the only thing they share. Backslashes, because the game's io opens it.
# Relative to the install root: Empire's cwd is the folder with Empire.exe.
stock_path = opt("stock", "EmpireScriptExtender\\lua\\production chains\\chain_stock.lua")
# Stock keys are per faction. Until the panel can ask who the player is, this
# is the faction the campaign side ticks for.
faction  = opt("faction", "britain")

abort "usage: ruby patch_market_labels.rb <government_screens.lua> [...] [--apply]" unless path && File.file?(path)

# ---- display names ---------------------------------------------------------
# The vanilla eight are not in chain.loc; their names are stable English and
# are listed here rather than parsed out of main.pack for one string each.
NAMES = {
  "res_coffee" => "Coffee", "res_cotton" => "Cotton", "res_furs"    => "Furs",
  "res_ivory"  => "Ivory",  "res_spices" => "Spices", "res_sugar"   => "Sugar",
  "res_tea"    => "Tea",    "res_tobacco" => "Tobacco",
}

# resources_onscreen_text_res_<key> in the shipped .loc is the real source for
# everything we added, rum included.
def read_loc(path)
  return {} unless File.file?(path)
  d = File.binread(path)
  return {} unless d[0, 2] == "\xFF\xFE".b && d[2, 3] == "LOC".b
  count = d[10, 4].unpack1("l<")
  pos = 14
  out = {}
  count.times do
    kl = d[pos, 2].unpack1("v"); pos += 2
    k  = d[pos, kl * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += kl * 2
    vl = d[pos, 2].unpack1("v"); pos += 2
    v  = d[pos, vl * 2].force_encoding("UTF-16LE").encode("UTF-8"); pos += vl * 2
    pos += 1
    out[k] = v
  end
  out
end
loc = read_loc(locfile)
# An empty loc is never correct here - it means the path is wrong, and the
# result is a table of bare keys that looks plausible enough to ship.
abort "no entries read from #{locfile} - wrong path? refusing to emit bare-key tooltips" if loc.empty?
loc.each do |k, v|
  next unless k =~ /\Aresources_onscreen_text_(res_.+)\z/
  NAMES[$1] = v
end

# ---- db key -> UI component name ------------------------------------------
ui = {}
NAMES.each_key { |k| ui[k] = k.sub(/\Ares_/, "") }     # vanilla: strip the prefix
# A MISSING CONFIG IS NOT A DEFAULT. Stripping `res_` is right for the vanilla
# eight and wrong for anything the mod renamed: res_corn's slot is `grain` and
# res_naval_supplies' is `navstores`. Falling back silently produced tables
# keyed "corn"/"naval_supplies", so Find("stk_corn") returned nil and those two
# goods had no tooltip and no stock display - on BOTH tabs, with no error
# anywhere. That shipped once, during the window when this file had vanished.
abort <<~MSG unless File.file?(config)
  #{config} is missing.
  Without it every db key falls back to a stripped `res_` name, which is WRONG
  for any commodity whose slot was renamed (res_corn -> grain,
  res_naval_supplies -> navstores). Regenerate it with build_chain_content.ps1
  rather than letting the fallback ship.
MSG
renamed = 0
File.read(config, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").each_line do |line|
  s = line.strip
  next if s.empty? || s.start_with?("#", ";")
  a, b = s.split(/[\s,]+/)
  next unless a && b && a.start_with?("res_")
  renamed += 1 if ui[a] != b
  ui[a] = b
end
warn "note: #{renamed} commodit#{renamed == 1 ? 'y' : 'ies'} have a slot name " \
     "differing from their db key" if renamed > 0

# ---- recipes ---------------------------------------------------------------
recipes = {}                      # output => [[input, qty], ...]
feeds   = Hash.new { |h, k| h[k] = [] }
if File.file?(manifest)
  File.read(manifest, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").each_line do |line|
    next unless line.start_with?("RECIPE|")
    f = line.strip.split("|")
    # output | BATCH | input1 | qty1 [| input2 | qty2] - the 2nd field is how
    # many are produced, so the tooltip has to say "every N" rather than
    # "each one", or it overstates the cost by the batch size.
    out_key = f[1]
    batch = f[2].to_i
    ins = []
    i = 3
    while i + 1 <= f.size - 1
      ins << [f[i], f[i + 1].to_i]
      i += 2
    end
    recipes[out_key] = { batch: batch, ins: ins }
    ins.each { |k, _| feeds[k] << out_key }
  end
end

def nm(names, k) = names[k] || k.sub(/\Ares_/, "")

# ---- build the Lua table ---------------------------------------------------
lines = []
ui.keys.sort.each do |dbkey|
  comp = ui[dbkey]
  parts = [nm(NAMES, dbkey)]
  if (r = recipes[dbkey])
    made = r[:ins].map { |k, q| "#{q} #{nm(NAMES, k)}" }.join(" + ")
    parts << (r[:batch] > 1 ? "Every #{r[:batch]} made from: #{made}" : "Made from: #{made}")
  end
  unless feeds[dbkey].empty?
    parts << "Used for: " + feeds[dbkey].map { |k| nm(NAMES, k) }.sort.join(", ")
  end
  text = parts.join("\\n").gsub('"', '\"')
  lines << %{  ["#{comp}"] = "#{text}",}
end

# UI component name -> DB key, so the panel can look a good up in the
# stockpile file, whose keys are the res_* names.
dbkey_lines = ui.keys.sort.map { |dbkey| %{  ["#{ui[dbkey]}"] = "#{dbkey}",} }

# The path uses LONG BRACKETS, not a quoted string. A Windows path inside
# "..." has its backslashes read as escapes, and Lua 5.1 silently DROPS
# unknown ones rather than erroring - so a quoted absolute Windows path compiles cleanly and
# then evaluates to "D:steamsteamapps...". The file never opens and the stock
# display stays empty with nothing in any log.
#
# (A comment must not sit inside the `\` continuation below either: it ends
# the expression, and the assignments after it are silently lost.)
table_lua = "g_market_tooltips = {\n" + lines.join("\n") + "\n}\n" \
          + "g_market_dbkey = {\n" + dbkey_lines.join("\n") + "\n}\n" \
          + "g_chain_stock_path = [[#{stock_path}]]\n" \
          + "g_chain_faction = #{faction.inspect}\n"

# ---- apply -----------------------------------------------------------------
src = File.read(path, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").gsub("\r\n", "\n")

if src.include?("g_market_tooltips")
  puts "already patched - nothing to do"
  exit 0
end

# The two loops are NOT adjacent - patch_market_scroll.rb inserts the slider
# wiring between them - so they are anchored separately, both asserted before
# either is written.
# NOTE: built by joining explicit lines, NOT with a squiggly heredoc - <<~
# strips the common leading whitespace, which silently removed the 4-space
# indentation these anchors need and made every match fail.
prices_loop = [
  %{    for k, v in pairs(trade_info.prices) do},
  %{      UIComponent(UIComponent(window:Find(k)):Find("dy_value")):SetStateText(v)},
  %{    end},
].join("\n")
changes_loop = [
  %{    for k, v in pairs(trade_info.price_changes) do},
  %{      UIComponent(UIComponent(window:Find(k)):Find("growth_arrow")):SetVisible(false)},
  %{    end},
].join("\n")
abort "anchor not found (ShowTrade prices loop)"        unless src.include?(prices_loop)
abort "anchor not found (ShowTrade price_changes loop)" unless src.include?(changes_loop)

new_prices = [
  %{    -- Stockpiles live in the CAMPAIGN lua_State and this panel runs in the},
  %{    -- UI one; the two cannot call each other. Both have io, so},
  %{    -- chain_stock.lua is the shared state - chain_sim writes it each turn,},
  %{    -- this reads it when the tab opens.},
  %{    local stock = {}},
  %{    do},
  %{      local sf = io.open(g_chain_stock_path, "rb")},
  %{      if sf ~= nil then},
  %{        local src = sf:read("*a")},
  %{        sf:close()},
  %{        local chunk = loadstring("return " .. src)},
  %{        if chunk ~= nil then},
  %{          local good, t = pcall(chunk)},
  %{          if good and type(t) == "table" then stock = t end},
  %{        end},
  %{      end},
  %{    end},
  %{    for k, v in pairs(trade_info.prices) do},
  %{      local slot = window:Find(k)},
  %{      if slot ~= nil then},
  %{        UIComponent(UIComponent(slot):Find("dy_value")):SetStateText(v)},
  %{        -- Hide the arrow HERE, over prices (23 keys), not over},
  %{        -- price_changes (8 - vanilla only), which left a green arrow},
  %{        -- showing on every added good.},
  %{        UIComponent(UIComponent(slot):Find("growth_arrow")):SetVisible(false)},
  %{        local tip = g_market_tooltips[k]},
  %{        if tip ~= nil then},
  %{          local db = g_market_dbkey[k]},
  %{          if db ~= nil then},
  %{            local have = stock["chain_" .. g_chain_faction .. "_" .. db] or 0},
  %{            local want = stock["target_" .. g_chain_faction .. "_" .. db] or 0},
  %{            if want > 0 then},
  %{              tip = tip .. "\\n\\nIn store: " .. have .. "  (holding back until " .. want .. ")"},
  %{            else},
  %{              tip = tip .. "\\n\\nIn store: " .. have .. "  (selling all)"},
  %{            end},
  %{          end},
  %{          UIComponent(slot):SetTooltipText(tip)},
  %{        end},
  %{      end},
  %{    end},
].join("\n")
src = src.sub(prices_loop, new_prices)
# Retire the old loop rather than leave it looking like the live one.
src = src.sub(changes_loop,
  "    -- growth_arrow is now hidden in the prices loop above; price_changes\n" \
  "    -- carries only the 8 vanilla commodities and cannot cover the rest.")

# the table goes in front of ShowTrade
fn = "function ShowTrade()"
abort "anchor not found (ShowTrade)" unless src.include?(fn)
src = src.sub(fn, table_lua + fn)

puts(apply ? "APPLIED" : "DRY RUN (pass --apply to write)")
puts "  tooltips generated : #{lines.size}"
puts "  recipes used       : #{recipes.size}"
puts "  growth_arrow loop  : price_changes -> prices"
puts "\nsample:"
%w[coffee rum steel cannon uniforms].each do |c|
  l = lines.find { |x| x.start_with?(%{  ["#{c}"]}) }
  puts "  " + l.strip.gsub('\\n', ' | ') if l
end
puts "\nsize: #{File.size(path)} -> #{src.bytesize} bytes"

if apply
  File.write(path, src, mode: "wb")     # no BOM: loadstring dies on one
  puts "\nNEXT: recompile with the game's own Lua (loadstring + string.dump via ESE)."
end
