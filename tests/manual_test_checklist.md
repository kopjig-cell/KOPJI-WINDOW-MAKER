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

## Phase 3 — generated components

- [ ] **Generate Components (dev)** places a 1200×1200 window at the
      origin and a 900×2100 door 1.8 m to its right, both standing
      upright; a messagebox lists two saved .skp paths under
      paraframe/components/.
- [ ] Window anatomy: 4 frame members (70 mm), one vertical mullion
      (2 panels default), translucent glass, sill protruding forward at
      the bottom.
- [ ] Select the window → **Resize Selected Component (dev)** → enter
      1800 × 1500: frame members stay 70 mm wide, the mullion re-centres,
      glass stretches, sill follows the width. One Ctrl+Z restores the
      old size in a single step.
- [ ] Native **Window → Component Options** on the window shows LenX,
      LenY, framewidth, panels, sillheight etc.; changing *panels* to 3
      and applying adds a second mullion, evenly spaced; panels = 1
      hides the mullion entirely.
- [ ] Scale tool: drag the window wider, then right-click →
      Dynamic Components → Redraw — members return to 70 mm and the
      mullion re-spaces; overall size keeps the scaled width.
- [ ] Door: leaf recessed in the frame, no bottom rail. Resize to
      1000 × 2200 keeps 60 mm frame members.
- [ ] Both .skp files exist on disk and open standalone in SketchUp
      (File → Open) showing the same parametric behavior.

## Phase 4 — placement tool

Setup: draw a simple vertical wall (a rectangle on the ground, push-pulled
up ~2.5 m, ~200 mm thick) to place onto.

- [ ] **Place Window** (menu or toolbar) starts the tool; a blue wireframe
      ghost of the window follows the cursor and snaps flat onto a wall
      face, oriented upright and centred on the cursor.
- [ ] Moving over the floor or empty space shows no ghost (only near-
      vertical faces are valid); the status bar explains what to do.
- [ ] Click on the wall places a real window, glued to the face, with its
      base ~900 mm above Z=0; the native cut opens a hole in that one face.
- [ ] The tool stays active — a second click places another window. Esc
      exits the tool (first Esc clears a typed size, second exits).
- [ ] Before clicking, type `1500` in the VCB (bottom-right) → ghost width
      becomes 1500 mm; type `1500;2000` → width 1500, height 2000; place
      and measure to confirm.
- [ ] **Place Door** behaves the same but the door sits on the floor
      (base at Z=0) and has no sill.
- [ ] Each placement is a single Undo step; Undo removes the instance and
      restores the wall face's cut.
- [ ] With Dynamic Components disabled, Place Window shows the friendly
      "needs Dynamic Components" message instead of starting.

## Phase 5 — wall cutting engine

Setup walls to place onto (try each): (a) a loose-geometry solid wall,
(b) the same wall made into a Group, (c) a cavity wall = two parallel
Groups ~50 mm apart, (d) a layered wall = block Group + a thin plaster
Group either side.

- [ ] Placing a window auto-cuts a clean rectangular hole through the wall,
      front and back faces, with reveal (jamb/head/sill) faces lining the
      opening in the wall's material.
- [ ] Cavity wall: BOTH leaves get cut in one placement. Layered wall: all
      layers cut, each keeping its own material on the reveals.
- [ ] Orbit through the opening — no leftover interior faces, no gaps; the
      wall reads as a proper hole.
- [ ] **Heal Selected (dev)** on the window refills the wall solid (hole
      gone). **Cut Selected (dev)** re-cuts it. **Recut Selected (dev)**
      does heal+cut in one go.
- [ ] Delete the window, then… (Phase 6 will auto-heal; for now Heal before
      deleting, or note the hole remains — healing on delete is Phase 6).
- [ ] A cut failure rolls back cleanly (whole wall intact) with a message,
      never a half-cut wall.
- [ ] Cut depth honours the setting (default 600 mm): a wall thicker than
      the setting is only cut to that depth.

## Phase 6 — observers (live behavior)

Setup: a solid wall with one placed window (cut opening present).

- [ ] **Delete** the window (select + Del): ~0.2 s later the wall heals
      itself back to solid, automatically.
- [ ] **Move** the window along the wall with the Move tool: the old
      opening heals and a new one is cut at the new position.
- [ ] **Scale** the window with the Scale tool (drag a corner/edge grip):
      after release, the frame members snap back to 70 mm (DC redraw),
      the mullion re-spaces, and the opening is recut to the new size.
- [ ] Rapid wiggling with the Move tool does not spam operations — the
      recut happens once after you stop (debounced).
- [ ] **Undo** after each of the above returns the model to the prior
      state without the observers fighting back (no surprise recuts right
      after an undo). Note: delete-then-auto-heal is two undo steps
      (heal, then the delete itself).
- [ ] Save the model with placed windows, close, reopen: moving/deleting
      a window still heals/recuts (observers re-attach on open).
- [ ] Ruby Console stays free of ParaFrame errors during all of the above.
