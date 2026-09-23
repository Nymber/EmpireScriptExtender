# ui_layout.rb - the layout half of the UI kit.
#
# Empire panels are XML produced by etwng's ui2xml. The one-shot scripts under
# tools/trademod/ each reimplemented the same five operations, and each one
# paid for a trap the next script then paid for again. This file is those
# operations, once.
#
# What is proven (see tools/ui/README.md and the trade-mod roadmaps):
#
#   * xml2ui writes <children count="N"> verbatim. Recompute every count after
#     moving nodes, or the .ui loads corrupt.
#   * A state's <i> pair is the BOUNDS. Its image_uses are the PIXELS. Resize
#     one without the other and the border stays at the old size.
#   * Only the first <u> of an image_use is an id. The rest are x/y/w/h,
#     stored unsigned, so -3 arrives as 4294967293 and looks like an id.
#   * Find() is recursive. A cloned component needs a name the original does
#     not use.
#   * A tab caption lives on the child `tab_title`, field [3], and that id
#     resolves in text/ui.loc. The literal text does not win.
#   * A vslider without a sibling display_window hangs the panel. Clone the
#     pair, and only inside a panel that already hosts that template.
#   * A commodity row is 49px, not the 26px icon. Pitch below that clips the
#     price into the next icon.
#
# What this file will not do: clone a template-bearing component into a panel
# that does not already host that template. dialogue_box crashed on exactly
# that (display_window + vslider, FAULT 00F4AD23). Leaf clones (text,
# checkbox, icon) across files are the ones that shipped.

require "nokogiri"

module UILayout
  module_function

  F_TEXT  = 0
  F_LOCID = 3

  def load(path)
    Nokogiri::XML(File.read(path, mode: "rb"))
  end

  def save(doc, path)
    File.binwrite(path, doc.to_xml(indent: 0, save_with: Nokogiri::XML::Node::SaveOptions::AS_XML))
  end

  def name_of(e)
    s = e.xpath("./s").first
    s ? s.text : ""
  end

  def find_named(doc, n)
    doc.xpath("//uientry").find { |e| name_of(e) == n }
  end

  def xy(e)
    i = e.xpath("./i")
    [i[0].text.to_i, i[1].text.to_i]
  end

  def set_xy!(e, x, y)
    i = e.xpath("./i")
    i[0].content = x.to_s
    i[1].content = y.to_s
  end

  # xml2ui trusts the attribute. Call this after every structural edit.
  def recompute_counts!(doc)
    fixed = 0
    doc.xpath("//children").each do |c|
      real = c.xpath("./uientry").size.to_s
      next if c["count"] == real
      c["count"] = real
      fixed += 1
    end
    fixed
  end

  # Shift component ids. image_use geometry is left alone: only its first <u>
  # is an id, and a negative offset is stored unsigned.
  def reid!(node, shift)
    node.xpath(".//u | ./u").each do |u|
      if u.parent.name == "image_use"
        next unless u.parent.xpath("./u").first.equal?(u)
      end
      v = u.text.to_i
      u.content = (v + shift).to_s if v > 0x1000
    end
  end

  def state_wh(e)
    st = e.xpath("./states/state").first
    return nil unless st
    i = st.xpath("./i")
    return nil unless i.size >= 2
    [i[0].text.to_i, i[1].text.to_i, i]
  end

  # Resize a component's first state AND the image_uses drawn at the old size.
  # Returns [old_w, old_h, image_uses_rewritten].
  def set_state_size!(e, w, h)
    wh = state_wh(e)
    raise "#{name_of(e)}: no state size" unless wh
    ow, oh, i = wh
    i[0].content = w.to_s
    i[1].content = h.to_s
    drawn = 0
    e.xpath("./states//image_uses//u").each do |u|
      next if u.parent.xpath("./u").first.equal?(u) # the image id
      if u.text.to_i == oh && u.to_s.include?("y size")
        u.content = h.to_s
        drawn += 1
      elsif u.text.to_i == ow && u.to_s.include?("x size")
        u.content = w.to_s
        drawn += 1
      end
    end
    [ow, oh, drawn]
  end

  # A pane frame is a 9-slice. bottom/BL/BR sit at H-corner; left/right/fill
  # span H-2*corner. Call this whenever the pane height changes.
  def grow_frame!(e, old_h, new_h, corner = 16)
    st = e.xpath("./states/state").first
    raise "#{name_of(e)}: no state" unless st
    moved = 0
    st.xpath(".//image_uses//u").each do |u|
      if u.text.to_i == old_h - corner && u.to_s.include?("y offset")
        u.content = (new_h - corner).to_s
        moved += 1
      elsif u.text.to_i == old_h - 2 * corner && u.to_s.include?("y size")
        u.content = (new_h - 2 * corner).to_s
        moved += 1
      end
    end
    moved
  end

  # Clone `from_name` as a sibling, with a fresh id and a new name.
  # prefix is applied to every descendant name so Find() cannot collide.
  def clone_named(doc, from_name, to_name, shift, prefix: nil)
    src = find_named(doc, from_name)
    raise "no component #{from_name.inspect}" unless src
    raise "#{to_name.inspect} already present" if find_named(doc, to_name)
    node = src.dup
    reid!(node, shift)
    node.xpath("./s").first.content = to_name
    if prefix
      node.xpath(".//uientry").each do |e|
        s = e.xpath("./s").first
        next unless s && !s.text.empty?
        s.content = prefix + s.text
      end
    end
    src.parent.add_child(node)
    node
  end

  # A government-screen tab is registered from its name, not a list.
  # `tab_trade` -> `tab_<id>`, caption on the child tab_title.
  # The loc key must also ship in text/ui.loc or the caption stays blank.
  def add_tab(doc, id:, label:, loc_key:, x:, show:, shift:)
    src = find_named(doc, "tab_trade")
    raise "no tab_trade" unless src
    raise "tab_#{id} already present" if find_named(doc, "tab_#{id}")
    tab = src.dup
    reid!(tab, shift)
    tab.xpath("./s").first.content = "tab_#{id}"
    set_xy!(tab, x, xy(src)[1])
    scr = tab.xpath("./s").find { |s| s.text.include?("Component.Call") }
    raise "tab_trade has no Select() script" unless scr
    scr.content = scr.text.gsub("ShowTrade", show)
    title = tab.xpath(".//uientry").find { |e| name_of(e) == "tab_title" }
    raise "cloned tab has no tab_title" unless title
    title.xpath("./states/state").each do |st|
      us = st.xpath("./unicode")
      raise "tab_title has #{us.size} text fields, expected 5" unless us.size == 5
      us[F_TEXT].content = label
      us[F_LOCID].content = loc_key
    end
    group = src.parent
    group = group.parent while group && group.name != "children"
    raise "tab_trade is not in a <children> array" unless group
    group.add_child(tab)
    tab
  end

  # Replace a tab's child 0 with a clone of `pane_name`, rebased so it lands
  # where the donor pane lands under tab_trade.
  def set_tab_content(doc, tab, pane_name, new_name, shift)
    donor = find_named(doc, pane_name)
    raise "no pane #{pane_name.inspect}" unless donor
    kids = tab.xpath("./children").first
    raise "tab has no <children>" unless kids
    old = kids.xpath("./uientry").first
    raise "tab has no content child" unless old
    trade = find_named(doc, "tab_trade")
    tx, ty = xy(trade)
    ox, oy = xy(old)
    mx, my = xy(donor)
    nx, ny = xy(tab)
    pane = donor.dup
    reid!(pane, shift)
    pane.xpath("./s").first.content = new_name
    set_xy!(pane, (tx + ox + mx) - nx, (ty + oy + my) - ny)
    old.replace(pane)
    pane
  end

  # Move every child of `pane` except `keep` into its display_window, and
  # rebase coordinates so they stay where they were on screen. This is what
  # makes the scrollbar clip them.
  def reparent_into_window(doc, pane, keep:)
    kids = pane.xpath("./children").first
    raise "#{name_of(pane)} has no children" unless kids
    dw = kids.xpath("./uientry").find { |e| name_of(e) == "display_window" }
    raise "#{name_of(pane)} has no display_window" unless dw
    dwx, dwy = xy(dw)
    dwkids = dw.xpath("./children").first
    unless dwkids
      dwkids = Nokogiri::XML::Node.new("children", doc)
      dwkids["count"] = "0"
      tmpl = dw.xpath("./s").last
      tmpl ? tmpl.add_previous_sibling(dwkids) : dw.add_child(dwkids)
    end
    moved = []
    kids.xpath("./uientry").each do |e|
      next if keep.include?(name_of(e))
      x, y = xy(e)
      set_xy!(e, x - dwx, y - dwy)
      e.unlink
      dwkids.add_child(e)
      moved << name_of(e)
    end
    moved
  end

  # Prefix the names of a pane's slot children so a cloned grid cannot be
  # found by the original panel's lookups.
  def prefix_slots(pane, prefix, window: "display_window")
    kids = pane.xpath("./children").first
    host = kids && kids.xpath("./uientry").find { |e| name_of(e) == window }
    host ||= pane
    n = 0
    (host.xpath("./children").first&.xpath("./uientry") || []).each do |slot|
      s = slot.xpath("./s").first
      next unless s && !s.text.empty? && !s.text.start_with?(prefix)
      s.content = prefix + s.text
      n += 1
    end
    n
  end

  # The scroll script needs these. overflow = content - window height.
  def scroll_pair(pane)
    kids = pane.xpath("./children").first
    raise "#{name_of(pane)} has no children" unless kids
    dw = kids.xpath("./uientry").find { |e| name_of(e) == "display_window" }
    vs = kids.xpath("./uientry").find { |e| name_of(e) == "vslider" }
    raise "#{name_of(pane)} needs display_window AND vslider (a bare slider hangs)" unless dw && vs
    [dw, vs]
  end
end
