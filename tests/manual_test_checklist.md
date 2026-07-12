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
