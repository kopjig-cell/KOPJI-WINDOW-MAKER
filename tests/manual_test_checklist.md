# ParaFrame — manual test checklist

Run in SketchUp on both Windows and macOS where possible. Grows with each
phase; the full end-to-end matrix lands in Phase 10.

## Phase 1 — scaffold & toolbar

- [ ] Fresh SketchUp start with the extension installed: no load errors in
      the Ruby Console (`Extensions → Developer → Ruby Console` should be
      clean).
- [ ] **Extensions → ParaFrame** submenu exists with: Place Window, Place
      Door, Component Library, Edit Component, Toggle Plan View, a
      separator, and Reload ParaFrame (dev).
- [ ] The **ParaFrame** toolbar appears on first run with five icons
      (window, door, library grid, sliders, plan symbol) and shows tooltips
      on hover.
- [ ] Each of the five commands (menu and toolbar) pops a "Coming in
      Phase…" messagebox and SketchUp stays responsive afterwards.
- [ ] Status bar shows a hint while hovering each toolbar button.
- [ ] **Reload ParaFrame (dev)** prints `[ParaFrame] reloaded N files` to
      the Ruby Console, no duplicate menu items or toolbars appear after
      reloading several times.
- [ ] Hide the toolbar, restart SketchUp: it stays hidden (state is
      remembered); show it again, restart: it comes back.
- [ ] `ruby build/package.rb` produces `dist/ParaFrame_<v>.rbz`; installing
      that .rbz via Extension Manager on a machine/profile without the dev
      loader yields the same menu + toolbar.
- [ ] Extension can be disabled and re-enabled from Extension Manager
      without errors.

## Phase 2 — DC bridge

- [ ] With Dynamic Components ENABLED: **Extensions → ParaFrame → DC Bridge
      Self-Test (dev)** pops ONE messagebox reading "ALL PASS" with 8 PASS
      lines; the same report appears in the Ruby Console.
- [ ] Key lines: "geometry resized (x=20")" and "child formula followed
      (ParentName!LenX) (child lenx=20.0)" — those prove the production
      resize! path (live scale → update_last_sizes → redraw) drives the
      real DC engine end to end.
- [ ] During the test a box flashes at the model origin and is gone
      afterwards; the model is otherwise untouched.
- [ ] Edit → Undo three times steps back through cleanup, resize, build;
      Redo replays them; the self-test still passes when run again.
- [ ] The "display-unit round-trip" line shows your model's units (e.g.
      `model units: mm` for a metric template).
- [ ] With Dynamic Components DISABLED (Extension Manager → Dynamic
      Components → disable, restart): the self-test pops a friendly
      "ParaFrame needs the Dynamic Components extension" message instead of
      crashing. Re-enable DC afterwards.
