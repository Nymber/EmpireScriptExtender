# UI kit

What the trade mod uses to add a panel control, extracted so the next mod does
not relearn it. The one-shot scripts in `tools/trademod/` still build the
shipped Stock Controls tab. This is the library those operations came from,
not a second builder.

Three pieces. The first two run offline. The third runs in the game.

| file | does |
|---|---|
| `ui_layout.rb` | clone, rename, resize, reparent, add a tab. XML in, XML out. |
| `ui_script.rb` | check that every `LuaCall` the layout makes is a function the panel defines. |
| `lua/ui/ui.lua` | the same idea at runtime: find, set text, move, scroll, clone a template. |

`ui.lua` only works in a UI lua_State (`ese.ps1 -UI`, or a panel script).
A campaign `mod.lua` has no `UIComponent`, and calling one raises. The
folder's own `mod.lua` logs and returns for that reason. Do not add `ui`
to `ese_mods.lua` unless you want that no-op log.

## A button that toggles it

A click is not something `ui.lua` can attach. The component has to carry a
script and an `OnMouseLClickUp` event pair, and `CreateComponentFromTemplate`
copies neither. `add_spawn_button.rb` clones `button_diplomacy` (already in
the campaign HUD, so not a foreign template) as `ese_ui_spawn`. The click
runs `OnSelect` in the button's own state and writes `1` to
`EmpireScriptExtender\lua\chain_tab.lua`. Calling the HUD root does not
work: the root's functions live in its `.luac`, and a pipe eval lands in a
different state. The government panel is a third state, so the file is the
channel. `add_stock_hide.rb` puts a close-button clone on the stock pane
that writes `0`, hides the tab, and switches to Trade. The panel script
reads the file on open and on its pulse. A missing file means the tab shows.

```
ruby add_spawn_button.rb layout.xml layout_spawn.xml
ruby ..\..\etwng\ui\bin\xml2ui layout_spawn.xml layout.ui
```

Pack the HUD result as a movie pack at `ui\campaign ui\layout`. Pack the
government layout and `government_screens.luac` in a movie pack that sorts
after `zz_chain.pack`. The HUD button only writes the flag; close and reopen
Government if the tab does not return while the panel is already open. Reload
the campaign after repacking; the HUD is built when the campaign loads.

`require` them from a script in this folder, or add `tools/ui` to `$LOAD_PATH`.

## A tab, the short version

```ruby
require_relative 'ui_layout'
doc = UILayout.load('government_screens.xml')
tab = UILayout.add_tab(doc, id: 'notes', label: 'Notes',
  loc_key: 'tab_title_NewState_Text_notes', x: 572,
  show: 'ShowNotes', shift: 0x00B10000)
UILayout.set_tab_content(doc, tab, 'world market', 'notes pane', 0x00B11000)
UILayout.recompute_counts!(doc)
UILayout.save(doc, 'out.xml')
```

The loc key has to ship in `text/ui.loc`. A literal caption does not win, and
`localisation.loc` is the wrong file for a tab title.

## Rules

- Recompute `<children count>` after every move. `xml2ui` writes the attribute
  as-is.
- Resize the state and its `image_uses` together. The state is the box; the
  image uses are the pixels.
- Do not renumber `image_use` geometry. Only its first `<u>` is an id.
- `Find()` is recursive. Prefix cloned names.
- A `vslider` without a `display_window` beside it hangs the panel. Clone the
  pair, and only into a panel that already hosts that template. A leaf
  (checkbox, text, icon) may cross files; a template-bearing component may not.
  `dialogue_box` crashed on the second kind.
- A commodity row is 49px. The icon is 26. Pitch below 49 clips the price.
- The panel script runs in the UI lua_State. It cannot call campaign code.
  One writer per shared file.
- `UIScript.check!` before packing. It fails when the layout calls a function
  the panel does not define. The other direction is not an error: a panel
  defines many functions the layout never names.

Bytecode still has to be produced by the game (`loadstring` + `string.dump`).
There is no `luac` on this machine, and a foreign one will not match.
