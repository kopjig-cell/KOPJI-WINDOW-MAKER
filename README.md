# ParaFrame

Parametric doors and windows for SketchUp, with automatic multi-layer wall
cutting, powered by the Dynamic Components engine.

- **Namespace:** `Kopji::ParaFrame`
- **Supported:** SketchUp 2021 – 2026, Windows and macOS (pure Ruby, no
  native binaries, `UI::HtmlDialog` only)
- **Requires:** the Dynamic Components extension (ships with SketchUp) must
  be enabled

ParaFrame is an original work. It is not affiliated with, nor derived from,
any other extension.

## Install (release build)

1. Run `ruby build/package.rb` (any Ruby 2.7+, no gems needed). This writes
   `dist/ParaFrame_<version>.rbz`.
2. In SketchUp: **Extensions → Extension Manager → Install Extension…** and
   pick the `.rbz`.
3. Restart SketchUp if prompted. The **ParaFrame** toolbar and the
   **Extensions → ParaFrame** menu appear.

To bump the version while packaging: `ruby build/package.rb --bump patch`
(or `minor` / `major`). The version lives in one place — the `VERSION`
constant in `paraframe.rb`.

## Dev-mode loading (work from the repo, no .rbz)

Copy `build/dev_loader.example.rb` into your SketchUp Plugins folder, rename
it to `paraframe_dev_loader.rb`, and edit the path inside to point at this
repository. The Plugins folder is:

- **Windows:** `%APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins`
- **macOS:** `~/Library/Application Support/SketchUp 20xx/SketchUp/Plugins`

The loader adds the repo root to Ruby's load path and requires
`paraframe.rb`, so SketchUp runs the extension straight from your working
copy. After editing source files, use **Extensions → ParaFrame → Reload
ParaFrame (dev)** to pick up changes without restarting SketchUp
(menu/toolbar wiring is only built once per session; restart if you change
that part).

## Repository layout

```
paraframe.rb                  Registration loader (SketchupExtension)
paraframe/
  main.rb                     Menu, toolbar, requires, dev reload
  core/                       dc_bridge, cutter, observers, settings
  tools/                      Placement tool, plan-view toggle
  ui/                         HtmlDialog dialogs + bundled html/css/js
  components/                 Bundled .skp dynamic components
  resources/icons/            Toolbar icons
  resources/thumbs/           Cached library thumbnails
build/package.rb              .rbz packager + version bump helper
tests/manual_test_checklist.md
```

## Build phases

The extension is being built in phases; each phase is testable in SketchUp
before the next begins.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Scaffold, menu, toolbar, packaging | ✅ |
| 2 | DC bridge (dynamic_attributes read/write, redraw) | ✅ |
| 3 | Generated casement window + door dynamic components | ✅ |
| 4 | Placement tool (ghost preview, glue-to-face) | ✅ |
| 5 | Multi-layer wall cutting + healing engine | ✅ |
| 6 | Observers (move/scale/erase → recut/heal) | ✅ |
| 7 | Configuration dialog | — |
| 8 | Component library dialog | — |
| 9 | Plan view mode | — |
| 10 | Packaging polish, checklist, guards | — |

## Signing for Extension Warehouse

`build/package.rb` produces an **unsigned** `.rbz`. To distribute through
Extension Warehouse (or to load without "unsigned extension" warnings under
strict loading policy), upload the `.rbz` on the
[SketchUp Developer Center](https://extensions.sketchup.com/developer_center)
— signing happens there as part of the upload flow and is deliberately not
automated here.
