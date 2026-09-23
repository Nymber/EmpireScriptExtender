# ui_script.rb - the panel-script half of the UI kit.
#
# A layout change that adds a control does nothing until the panel's Lua
# names a function the control calls, and defines that function. The stock
# tab shipped with a dead control exactly once because those two sets were
# not compared.
#
# Lua here is Lua 5.1, and the panel script runs in the UI lua_State. It
# cannot call campaign functions. Share through a file, one writer per file.

module UIScript
  module_function

  # Every LuaCall("Name") in a layout must be a function the panel defines,
  # and the other way round for the prefix you care about. A name on one
  # side only is a silently dead control.
  def calls(xml)
    xml.scan(/LuaCall\("([A-Za-z_][A-Za-z0-9_]*)"/).flatten.uniq.sort
  end

  def definitions(lua)
    lua.scan(/^function ([A-Za-z_][A-Za-z0-9_]*)\s*\(/).flatten.uniq.sort
  end

  # Only names the layout calls are checked. A panel defines many functions
  # nothing in the layout names (ShowTrade is one); flagging those is noise.
  # A called name with no definition is the dead control.
  def check!(xml, lua, prefix:)
    called = calls(xml).select { |n| n.start_with?(prefix) }
    defined = definitions(lua)
    missing = called - defined
    raise "layout calls #{missing.join(', ')} but the panel does not define them" unless missing.empty?
    called
  end

  # Idempotent insert. marker is a line that already exists; the block is
  # written once, immediately before it.
  def insert_before(src, marker, block, guard:)
    return src if src.include?(guard)
    i = src.index(marker)
    raise "marker not found: #{marker.inspect}" unless i
    src.dup.insert(i, block)
  end

  # A government-screen tab shows its content by calling Show<Name>().
  # The function has to exist or the tab click errors and the pane stays hidden.
  def show_fn(name, body_lines)
    body = body_lines.map { |l| "  #{l}" }.join("\n")
    "function Show#{name}()\n#{body}\nend\n"
  end

  # Vanilla scrollbar contract, copied from Supply/Exports:
  #   slider:SetProperty("maxValue", content_h - window:Height())
  #   slider:LuaCall("Reset")
  #   slider:SetProperty("Notify", Address)
  #   on notify: child:MoveTo(x, base_y - value)
  # overflow must be the window height, not the row span, or it overscrolls
  # by one row.
  def scroll_init(slider_var, pane, slider = "vslider")
    [
      "#{slider_var} = UIComponent(UIComponent(this:Find(#{pane.inspect})):Find(#{slider.inspect}))",
      "#{slider_var}:SetProperty(\"Notify\", Address)",
    ]
  end

  # Position() returns x, y. MoveTo takes both. Passing the pair as the
  # x argument is how a row walks off the left of the pane.
  def scroll_update(fn, child_var)
    <<~LUA
      function #{fn}(value)
        local x, _ = #{child_var}:Position()
        #{child_var}:MoveTo(x, #{child_var}_base_y - value)
      end
    LUA
  end
end
