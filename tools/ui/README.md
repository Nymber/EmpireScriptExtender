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
| `add_stock_tab_toggle.rb` | add the persistent Stock Controls show/hide button to the government-screen layout. |
| `ui_kit_selftest.rb` | check the UI layout and script helpers without launching the game. |
| `lua/ui/ui.lua` | the same idea at runtime: find, set text, move, scroll, clone a template. |

`ui.lua` only works in a UI lua_State (`ese.ps1 -UI`, or a panel script).
A campaign `mod.lua` has no `UIComponent`, and calling one raises. The `ui`
manifest records ownership but is skipped in campaign and battle states. ESE
does not yet have a general UI-state mod autoexec; panel scripts continue to
load `ui.lua` themselves.

## A button that toggles it

A click is not something `ui.lua` can attach. The component has to carry a
script and an `OnMouseLClickUp` event pair, and `CreateComponentFromTemplate`
copies neither. `add_spawn_button.rb` clones `button_diplomacy` (already in
the campaign HUD, so not a foreign template) as `ese_ui_spawn`. The click
runs `OnSelect` in the button's own state. That function opens `dialogue_box`,
and closes it on the next click. Calling the HUD root does not work: the
root's functions live in its `.luac`, and a pipe eval lands in a different
state. Put the work in `OnSelect` itself.

`add_stock_tab_toggle.rb` adds a persistent header button for the Stock
Controls tab. It clones the tab's own artwork, removes the cloned storage grid,
and places the button directly under `government_screens`, outside `tab_group`.
Its click handler checks the panel and tab lookups, returns to Trade before
hiding the Stock Controls tab, and can show the tab again from the same button.
The previous hide button was inside the tab it hid, so it could not reopen it.
The toggle layout is deployed in `data/zz_stocktab.pack` (SHA-256
`146EA66C3D64B03ABEC78A9E5C35F59E6084E5CA9E3740E6580BCED332692511`).
Structural and pack hash checks passed; the click behavior still needs a live
campaign check. The generated pack is intentionally excluded from the ESE
release archive; the builder and instructions ship under `tools/ui`.

Build the toggle layout from the extracted government-screen XML, then convert
it back to the game's `.ui` format before packing. The converter is part of
the shared ETW tools folder, not this ESE release, so resolve it through the
path helper instead of assuming a drive or install location:

```
ruby tools/ui/add_stock_tab_toggle.rb government_screens.xml government_screens_toggle.xml
$paths = .\empire_paths.ps1 -Json | ConvertFrom-Json
$xml2ui = Join-Path $paths.ToolsDir 'etwng\ui\bin\xml2ui'
& $xml2ui government_screens_toggle.xml '.\staged\stocktab_toggle\ui\campaign ui\government_screens\government_screens'
.\empire.ps1 pack '.\staged\stocktab_toggle' zz_stocktab.pack -Deploy
```

Keep the button under the panel root, outside `tab_group`; the panel's tab
manager treats each child of that group as a content tab. Deployment requires
Empire to be closed. The pack contains the updated layout and the existing
government-screen script; generated packs are excluded from ESE release ZIPs.

```
ruby add_spawn_button.rb layout.xml layout_spawn.xml
$paths = .\empire_paths.ps1 -Json | ConvertFrom-Json
$xml2ui = Join-Path $paths.ToolsDir 'etwng\ui\bin\xml2ui'
& $xml2ui layout_spawn.xml layout.ui
```

Pack the HUD result as a movie pack at `ui\campaign ui\layout`. A local build
may exist at `lua/ui/ese_ui_spawn.pack`, but generated packs are excluded from
releases. Build and deploy it explicitly with the pack workflow while the game
is closed. The `ui` registry entry describes Lua ownership and does not install
the movie pack.
Reload the campaign after the next launch; the HUD is built when the campaign
loads. The government override, if used, is a second movie pack that sorts
after `zz_chain.pack`.

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
