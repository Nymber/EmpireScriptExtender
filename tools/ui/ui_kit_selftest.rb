# Exercises the kit against a tiny fake panel, not a real .ui.
# A pass here means the helpers do what they claim. It does not mean a
# panel built with them will render - only the game can say that.

require_relative "ui_layout"
require_relative "ui_script"

def die(m) = (warn m; exit 1)

xml = <<~XML
  <?xml version="1.0"?>
  <uientry>
    <s>root</s>
    <i>0</i><i>0</i>
    <children count="1">
      <uientry>
        <s>tab_trade</s>
        <i>342</i><i>68</i>
        <u>100000</u>
        <s>function Select()
    Component.Call("Parent.Parent.LuaCall", "ShowTrade")
  end</s>
        <children count="1">
          <uientry>
            <s>trade content</s>
            <i>10</i><i>20</i>
            <children count="1">
              <uientry>
                <s>tab_title</s>
                <i>0</i><i>0</i>
                <states>
                  <state>
                    <unicode>Trade</unicode>
                    <unicode></unicode>
                    <unicode></unicode>
                    <unicode>tab_title_NewState_Text_160050</unicode>
                    <unicode></unicode>
                  </state>
                </states>
              </uientry>
            </children>
          </uientry>
        </children>
      </uientry>
    </children>
  </uientry>
XML

doc = Nokogiri::XML(xml)
tab = UILayout.add_tab(doc, id: "notes", label: "Notes",
  loc_key: "tab_title_NewState_Text_notes", x: 457,
  show: "ShowNotes", shift: 0x00A40000)
die "tab not added" unless UILayout.find_named(doc, "tab_notes")
die "caption loc key missing" unless tab.to_s.include?("tab_title_NewState_Text_notes")
die "click still routes to ShowTrade" if tab.to_s.include?("ShowTrade")
die "id not shifted" unless tab.to_s.include?("<u>#{100000 + 0x00A40000}</u>")

# image_use geometry must survive reid!: a -3 stored unsigned is not an id.
frag = Nokogiri::XML('<image_use><u>160050</u><u>4294967293</u></image_use>').root
UILayout.reid!(frag, 0x10000)
die "image id not shifted" unless frag.xpath("./u")[0].text == (160050 + 0x10000).to_s
die "geometry was renumbered" unless frag.xpath("./u")[1].text == "4294967293"

fixed = UILayout.recompute_counts!(doc)
die "counts not recomputed" unless fixed > 0
die "count still stale" if doc.to_s =~ /count="1"/ && doc.xpath("//children").any? { |c|
  c["count"].to_i != c.xpath("./uientry").size
}

lua = "function ShowNotes()\nend\nfunction ShowTrade()\nend\n"
UIScript.check!(doc.to_s + 'LuaCall("ShowNotes")', lua, prefix: "Show")
begin
  UIScript.check!('LuaCall("ShowMissing")', lua, prefix: "Show")
  die "check! accepted a missing function"
rescue RuntimeError
end

src = "function Init()\nend\n"
out = UIScript.insert_before(src, "function Init", "function ShowNotes()\nend\n", guard: "function ShowNotes")
die "insert failed" unless out.include?("function ShowNotes")
again = UIScript.insert_before(out, "function Init", "function ShowNotes()\nend\n", guard: "function ShowNotes")
die "insert was not idempotent" unless again.scan("function ShowNotes").size == 1

puts "ui kit selftest: ok"
