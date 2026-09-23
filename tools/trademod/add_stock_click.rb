# add_stock_click.rb - give every slot in the Stock Controls tab a click
# handler, so clicking a commodity cycles its hold-back target.
#
# THE SLOTS ARE ALREADY INTERACTIVE. Their flag block is [1,1,0,1,0,0,0],
# byte for byte the same as `arrow_L`/`arrow_R`, which are working buttons in
# this very panel - and they already receive mouse-over, since the market
# tooltips work. What they lack is a script, and that is all this adds.
#
# THE IDIOM IS VANILLA'S, including walking up by NAME:
#
#     local this = UIComponent(Address)
#     local parent = UIComponent(this:Parent("government_screens"))
#     function OnLeftClickUp()
#       parent:LuaCall("SelectPrevBuildPolicy")
#     end
#
# `this:Parent("government_screens")` matters: the slots sit four levels down
# (display_window -> stock market -> tab_stock -> tab_group -> panel), and a
# Parent.Parent.Parent chain would break the moment the layout is re-nested.
#
# EVENT NAMES. Across this panel vanilla uses only OnLeftClickUp (7x),
# OnLClickUp (2x) and OnSelect. There is NO right-click precedent here, so the
# left click wraps the whole ladder and is a complete control by itself. An
# OnRightClickUp handler is emitted as well - if the engine never dispatches
# that event the function is simply never called, which costs nothing.
#
# Usage
#   ruby add_stock_click.rb <in.xml> <out.xml> [--apply]

require "nokogiri"

src, dst = ARGV[0], ARGV[1]
apply = ARGV.include?("--apply")
abort "usage: ruby add_stock_click.rb <in.xml> <out.xml> [--apply]" unless src && dst && File.file?(src)

doc = Nokogiri::XML(File.read(src, mode: "rb"))
def name_of(e) = (s = e.xpath("./s").first) ? s.text : ""

pane = doc.xpath("//uientry").find { |e| name_of(e) == "stock market" }
abort "no 'stock market' pane - run add_stock_tab.rb first" unless pane

# The script is the <s> tagged `<!-- script -->`, which is s[2]. Find it by the
# COMMENT rather than the index: writing s[2] blind on a component whose shape
# differs would overwrite its parent name or template and fail far from here.
def script_field(e)
  e.xpath("./s").find do |s|
    c = s.next_sibling
    c = c.next_sibling while c && c.text? && c.text.strip.empty?
    c && c.comment? && c.text.strip == "script"
  end
end

dw = pane.xpath("./children/uientry").find { |e| name_of(e) == "display_window" }
abort "'stock market' has no display_window" unless dw

slots = dw.xpath("./children/uientry").select { |e| name_of(e).start_with?("stk_") }
abort "no stk_ slots found - add_stock_tab.rb renames them, so it must run first" if slots.empty?

wrote, skipped = 0, []
slots.each do |slot|
  full = name_of(slot)            # stk_coffee
  good = full.sub(/\Astk_/, "")   # coffee
  f = script_field(slot)
  if f.nil?
    skipped << "#{full} (no script field)"
    next
  end
  unless f.text.strip.empty?
    # Refuse to clobber an existing script rather than silently replacing it.
    skipped << "#{full} (already has a script)"
    next
  end
  # \r\n to match the line endings vanilla's own inline scripts use.
  # ZERO-ARGUMENT LuaCall, which is the form vanilla proves here
  # (`parent:LuaCall("SelectPrevBuildPolicy")`). Passing the commodity name as
  # an argument would rest on LuaCall dispatching a string, which nothing
  # demonstrates; parking it in a global does not work either, because each
  # panel script has its own environment (probed live: none of the panel's
  # globals are visible outside it). patch_stock_cycle.rb emits one named
  # wrapper per commodity so no argument is needed at all.
  f.content = [
    'local this = UIComponent(Address)',
    'local parent = UIComponent(this:Parent("government_screens"))',
    '',
    'function OnLeftClickUp()',
    "\tparent:LuaCall(\"CycleStock_#{good}\")",
    'end',
    '',
    'function OnRightClickUp()',
    "\tparent:LuaCall(\"CycleStockDown_#{good}\")",
    'end',
  ].join("\r\n")
  wrote += 1
end

puts "slots found   : #{slots.size}"
puts "handlers added: #{wrote}"
skipped.each { |s| puts "  SKIPPED #{s}" }
abort "no handlers were added" if wrote.zero?

# xml2ui writes <children count=..> verbatim; this tool adds no components, so
# the counts should already be right. Check rather than assume.
bad = doc.xpath("//children").reject { |c| c["count"].to_i == c.xpath("./uientry").size }
abort "#{bad.size} <children> count(s) disagree with reality" unless bad.empty?

if apply
  File.write(dst, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML), mode: "wb")
  puts "\nwritten: #{dst}"
else
  puts "\nDRY RUN (pass --apply to write)"
end
