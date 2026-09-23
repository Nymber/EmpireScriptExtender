# gen_building_descriptions.rb - write the short/long description .loc entries
# for the production-chain buildings.
#
# THE KEY FORMAT, AND THE MISTAKE IT FIXES
#   Two nearby tables use DIFFERENT key shapes, and conflating them produces
#   entries that are invisible in game - the engine finds no string and draws
#   nothing, with no error anywhere:
#
#     building_culture_variants_name_<level><culture>     <- CONCATENATED
#     building_description_texts_short_description_<key>  <- key AS IS
#     building_description_texts_long_description_<key>
#
#   building_culture_variants has a COMPOSITE primary key (building, culture)
#   and the loc key is the two joined with no separator - vanilla really does
#   say `..._small_coffee_plantationeuropean`. building_description_texts has a
#   SINGLE key field whose value already ends in `_european`, so the loc key is
#   `..._small_coffee_plantation_european`, WITH the underscore.
#
#   The chain buildings' descriptions had been written in the concatenated
#   shape, so all 33 buildings showed no description at all.
#
# HOUSE STYLE (measured across vanilla's 236 pairs)
#   short: one or two sentences, NO leading newline
#   long : begins with two newlines (235 of 236 do)
#
# Output is a loctool `addfile` manifest: key|value, with \n for newlines.
#
# Usage
#   ruby gen_building_descriptions.rb [--manifest F] [--out F]

def opt(n, d)
  i = ARGV.index("--#{n}")
  i && ARGV[i + 1] ? ARGV[i + 1] : d
end
here     = File.dirname(File.expand_path(__FILE__))
manifest = opt("manifest", File.join(here, "chain_manifest.txt"))
outfile  = opt("out", File.join(here, "chain_descriptions.txt"))

LEVELS = [["small", "Small"], ["large", "Large"], ["grand", "Grand"]]
SCALE  = { "small" => 1.0, "large" => 1.7, "grand" => 2.7 }

# What the building is, in its own words. Generic filler is what the buildings
# already had; this is the part that makes the panel worth reading.
FLAVOUR = {
  "coal_mine" => "Coal is the fuel of the new industry. Without it furnaces stay cold, powder mills stand idle, and the finest ore in the world stays a rock.",
  "saltpetre_works" => "Saltpetre is scraped from nitrous earth and refined in long beds. It is the irreplaceable ingredient of gunpowder, and a state that cannot make it must buy it from those who can.",
  "lead_mine" => "Soft, heavy and easily cast, lead becomes shot in any village forge. It is the least glamorous of metals and the one an army runs out of first.",
  "foundry" => "Iron and coal go in at one end and steel comes out at the other: the stuff of barrels, bayonets and great guns.",
  "powder_mill" => "Saltpetre and charcoal, ground fine and corned into grains. Powder mills are built well away from anything that matters, and for excellent reason.",
  "cartridge_works" => "Powder and ball wrapped in paper, made by the hundred thousand. A soldier without cartridges is a man holding an expensive club.",
  "musket_manufactory" => "Lock, stock and barrel, made to a pattern so that any part fits any weapon. Standardisation is worth more to an army than craftsmanship.",
  "cannon_works" => "Great guns are cast, bored and proofed here. A single flaw in the casting bursts the barrel and kills the crew that served it.",
  "weavers_mill" => "Raw cotton is carded, spun and woven into cloth by the bolt, in quantities no cottage loom could match.",
  "uniform_works" => "Cloth becomes coats. An army marches on its stomach, but it is recognised by its facings.",
  "naval_yard" => "Timber, tar, cordage and iron fittings: the unglamorous stores without which no fleet keeps the sea.",
  "rum" => "Molasses left over from the sugar harvest is fermented and distilled into rum. It is the drink of sailors and of the men who prey on them, and it travels better than beer.",
}

SLOT_TEXT = {
  "coal" => "a coal seam", "saltpetre" => "a saltpetre deposit", "lead" => "a lead deposit",
  "town-metal" => "an industrial town", "settlement_ordnance" => "an ordnance site",
  "town-textile" => "a textile town", "port" => "a port",
  "caribbean" => "cane-growing land", "cuba" => "cane-growing land",
}

names   = {}
recipes = {}
blds    = []
units   = {}   # commodity -> unit noun, for the effect descriptions
File.read(manifest, mode: "rb").sub(/\A\xEF\xBB\xBF/n, "").each_line do |line|
  f = line.strip.split("|")
  case f[0]
  when "COM"  then names[f[1]] = f[5]
  when "UNIT" then units[f[1]] = f[2]
  when "RES"
    names[f[1]] ||= f[1].sub(/\Ares_/, "").split("_").map(&:capitalize).join(" ")
    units[f[1]] = f[2]
  when "BLD"
    # Field 2 may hold several slots joined with '+'; field 10 overrides the
    # level-name stem (the rum chain is `rum`, its levels are `*_rum_distillery`).
    blds << { chain: f[1], slot: f[2].to_s.split("+").first, com: f[3],
              out: f[4].to_i, name: f[6],
              stem: (f[10].nil? || f[10].empty?) ? f[1] : f[10] }
  when "RECIPE"
    # output | BATCH | input1 | qty1 [| input2 | qty2]
    # The 2nd field is how many are produced, and ignoring it understated the
    # cost per unit by the batch size ("each one needs 4 Steel" when 4 steel
    # makes FOUR muskets).
    ins = []
    i = 3
    while i + 1 <= f.size - 1
      ins << [f[i], f[i + 1].to_i]
      i += 2
    end
    recipes[f[1]] = { batch: f[2].to_i, ins: ins }
  end
end
names["res_rum"] ||= "Rum"
def nm(names, k) = names[k] || k.sub(/\Ares_/, "").split("_").map(&:capitalize).join(" ")

rows = []
blds.each do |b|
  LEVELS.each do |tag, word|
    key  = "#{tag}_#{b[:stem]}_european"
    outq = (b[:out] * SCALE[tag]).round
    good = nm(names, b[:com])

    # A RECIPE is PER UNIT, not per turn - res_cannon|1|res_steel|3|res_coal|1
    # means one cannon costs three steel and one coal, so a grand works making
    # sixteen needs forty-eight. Saying "produces 16, consumes 3 Steel" would
    # read as a per-turn total and understate the real draw enormously.
    r = recipes[b[:com]]
    short = "Produces up to #{outq} #{good} each turn."
    if r
      short += " Every #{r[:batch]} need " +
               r[:ins].map { |k, q| "#{q} #{nm(names, k)}" }.join(" and ") + "."
    end

    long = "\\n\\n#{FLAVOUR[b[:chain]]}"
    long += "\\n\\nA #{word.downcase} #{b[:name].downcase} produces up to #{outq} #{good} per turn"
    if r
      # Per-turn draw = output / batch x each input's quantity.
      draw = r[:ins].map { |k, q| [nm(names, k), (outq.to_f / r[:batch] * q).ceil] }
      long += ", made #{r[:batch]} at a time from " +
              r[:ins].map { |k, q| "#{q} #{nm(names, k)}" }.join(" and ") +
              " - up to " + draw.map { |n2, q| "#{q} #{n2}" }.join(" and ") +
              " a turn at full output"
    end
    long += "."
    if (st = SLOT_TEXT[b[:slot]])
      long += " It can only be built where there is #{st}."
    end
    unless (users = recipes.select { |_, v| v[:ins].any? { |k, _| k == b[:com] } }.keys).empty?
      long += "\\n\\n#{good} is needed to make " + users.map { |k| nm(names, k) }.sort.join(", ") + "."
    end

    rows << "building_description_texts_short_description_#{key}|#{short}"
    rows << "building_description_texts_long_description_#{key}|#{long}"
  end
end

# ---- effect descriptions --------------------------------------------------
# The building panel's "Effects" section renders
# effects_description_<effect>, and ONLY commodity_prod_rum had one - which is
# why every chain building showed an effect icon with no text beside it.
# Vanilla's phrasing, from the rum entry that works:
#     "%n barrels of rum produced each turn"
# %n is the value; the noun is the commodity's own unit.
units["res_rum"] ||= "barrels"
effect_rows = []
names.keys.sort.each do |dbkey|
  next unless units[dbkey]
  short = dbkey.sub(/\Ares_/, "")
  noun  = units[dbkey]
  noun  = nil if noun == "(none)" || noun.to_s.empty?
  label = nm(names, dbkey).downcase
  text  = noun ? "%n #{noun} of #{label} produced each turn"
               : "%n #{label} produced each turn"
  effect_rows << "effects_description_commodity_prod_#{short}|#{text}"
end
rows.concat(effect_rows)

File.write(outfile, rows.join("\n") + "\n", mode: "wb")
puts "#{blds.size} buildings x #{LEVELS.size} levels -> #{rows.size} entries"
puts "written: #{outfile}"
puts "\nsample:"
rows.first(2).each { |r| puts "  " + r[0, 150] }
puts "  ..."
rows.select { |r| r.include?("grand_cannon_works") }.each { |r| puts "  " + r[0, 200] }
