# frozen_string_literal: true

# Generator for the basic parametric casement window.
#
# Anatomy (all authored flat — X width, Y height, Z depth; see builder.rb):
#
#   ┌───────────────────────────┐  ← head (between the jambs)
#   │ ┌───────┐ │ ┌───────┐ │ │
#   │ │ glass │ M │ glass │ J │   J = jamb (full height, fixed width)
#   │ │       │ │ │       │ │ │   M = mullion (copies = panels-1,
#   │ └───────┘ │ └───────┘ │ │       re-spaced by formula)
#   ├───────────────────────────┤  ← bottom rail
#   └━━━━━━━━━━━━━━━━━━━━━━━━━━━┘  ← sill (protrudes out of the wall,
#                                     toggleable via "hassill")
#
# User inputs (root definition, editable later via the config dialog):
#   lenx / leny   window width / height (driven by DCBridge.resize!)
#   framewidth    visible width of frame members
#   framedepth    frame depth into the wall
#   panels        number of glazed panels (mullions = panels - 1)
#   glassthickness, silldepth, sillthickness
#   hassill       1 = show sill, 0 = hide
#   sillheight    used by the placement tool (Phase 4), not by geometry
#
# Scale-tool friendliness comes from the formulas: jambs/head/rail keep
# their framewidth, the glass and mullions absorb/re-space the change.

require 'sketchup.rb'

module Kopji
  module ParaFrame
    module CasementWindow

      # Defaults (mm → inches via the API's Numeric#mm).
      WIDTH        = 1200
      HEIGHT       = 1200
      FRAME_W      = 70
      FRAME_D      = 70
      PANELS       = 2
      SILL_HEIGHT  = 900
      GLASS_T      = 4
      SILL_D       = 40
      SILL_T       = 30

      module_function

      # Builds the casement window definition inside +model+ and returns
      # it. Caller is responsible for the surrounding operation.
      def build(model)
        w  = WIDTH.mm
        h  = HEIGHT.mm
        fw = FRAME_W.mm
        fd = FRAME_D.mm
        gt = GLASS_T.mm
        sd = SILL_D.mm
        st = SILL_T.mm

        frame_mat = Builder.material(model, 'PF Frame', [235, 232, 225])
        glass_mat = Builder.material(model, 'PF Glass', [160, 200, 215], 0.35)
        sill_mat  = Builder.material(model, 'PF Sill',  [200, 196, 188])

        defn = Builder.new_root(model, 'PF_Casement', :window)
        r = defn.name # actual (possibly #1-suffixed) name — formulas use it

        # Root user inputs. LenX/LenY are synced from live geometry by the
        # engine; the rest are plain dictionary inputs read by formulas.
        DCBridge.declare_input(defn, :lenx, w, label: 'LenX', formlabel: 'Width')
        DCBridge.declare_input(defn, :leny, h, label: 'LenY', formlabel: 'Height')
        DCBridge.declare_input(defn, :framewidth, fw, formlabel: 'Frame Width')
        DCBridge.declare_input(defn, :framedepth, fd, formlabel: 'Frame Depth')
        DCBridge.declare_input(defn, :panels, PANELS, formlabel: 'Panels')
        DCBridge.declare_input(defn, :sillheight, SILL_HEIGHT.mm,
                               formlabel: 'Sill Height (placement)')
        DCBridge.declare_input(defn, :hassill, 1, formlabel: 'Has Sill (1/0)')
        DCBridge.declare_input(defn, :glassthickness, gt, formlabel: 'Glass Thickness')
        DCBridge.declare_input(defn, :silldepth, sd, formlabel: 'Sill Depth')
        DCBridge.declare_input(defn, :sillthickness, st, formlabel: 'Sill Thickness')

        # --- frame: two jambs, head, bottom rail ---------------------------
        jamb_l = Builder.box_child(model, defn, 'PF_Casement_JambL',
                                   x: 0, y: 0, w: fw, h: h, d: fd, material: frame_mat)
        Builder.drive(jamb_l,
                      lenx: ["#{r}!framewidth", fw],
                      leny: ["#{r}!LenY", h],
                      lenz: ["#{r}!framedepth", fd])

        jamb_r = Builder.box_child(model, defn, 'PF_Casement_JambR',
                                   x: w - fw, y: 0, w: fw, h: h, d: fd, material: frame_mat)
        Builder.drive(jamb_r,
                      lenx: ["#{r}!framewidth", fw],
                      leny: ["#{r}!LenY", h],
                      lenz: ["#{r}!framedepth", fd],
                      x:    ["#{r}!LenX-#{r}!framewidth", w - fw])

        head = Builder.box_child(model, defn, 'PF_Casement_Head',
                                 x: fw, y: h - fw, w: w - 2 * fw, h: fw, d: fd,
                                 material: frame_mat)
        Builder.drive(head,
                      lenx: ["#{r}!LenX-2*#{r}!framewidth", w - 2 * fw],
                      leny: ["#{r}!framewidth", fw],
                      lenz: ["#{r}!framedepth", fd],
                      x:    ["#{r}!framewidth", fw],
                      y:    ["#{r}!LenY-#{r}!framewidth", h - fw])

        rail = Builder.box_child(model, defn, 'PF_Casement_Rail',
                                 x: fw, y: 0, w: w - 2 * fw, h: fw, d: fd,
                                 material: frame_mat)
        Builder.drive(rail,
                      lenx: ["#{r}!LenX-2*#{r}!framewidth", w - 2 * fw],
                      leny: ["#{r}!framewidth", fw],
                      lenz: ["#{r}!framedepth", fd],
                      x:    ["#{r}!framewidth", fw])

        # --- glazing: one sheet spanning the opening, centred in depth -----
        glass = Builder.box_child(model, defn, 'PF_Casement_Glass',
                                  x: fw, y: fw, z: -(fd - gt) / 2.0,
                                  w: w - 2 * fw, h: h - 2 * fw, d: gt,
                                  material: glass_mat)
        Builder.drive(glass,
                      lenx: ["#{r}!LenX-2*#{r}!framewidth", w - 2 * fw],
                      leny: ["#{r}!LenY-2*#{r}!framewidth", h - 2 * fw],
                      lenz: ["#{r}!glassthickness", gt],
                      x:    ["#{r}!framewidth", fw],
                      y:    ["#{r}!framewidth", fw],
                      z:    ["-(#{r}!framedepth-#{r}!glassthickness)/2", -(fd - gt) / 2.0])

        # --- mullions: copies re-spaced from the panel count ----------------
        # panels P → P-1 mullions. The DC "copies" attribute clones the
        # original (copy index 0), so copies = P-2 for P ≥ 2; a single
        # panel hides the original instead (copies can't go negative).
        interior = w - 2 * fw
        pitch = interior / PANELS
        mull_x0 = fw + pitch - fw / 2.0
        mullion = Builder.box_child(model, defn, 'PF_Casement_Mullion',
                                    x: mull_x0, y: fw, w: fw, h: h - 2 * fw, d: fd,
                                    material: frame_mat)
        Builder.drive(mullion,
                      lenx:   ["#{r}!framewidth", fw],
                      leny:   ["#{r}!LenY-2*#{r}!framewidth", h - 2 * fw],
                      lenz:   ["#{r}!framedepth", fd],
                      y:      ["#{r}!framewidth", fw],
                      x:      ["#{r}!framewidth+(copy+1)*(#{r}!LenX-2*#{r}!framewidth)" \
                               "/#{r}!panels-#{r}!framewidth/2", mull_x0],
                      copies: ["IF(#{r}!panels>1,#{r}!panels-2,0)", 0],
                      hidden: ["IF(#{r}!panels<2,1,0)", 0])

        # --- sill: protrudes OUT of the wall (z > 0), toggleable ------------
        # Drawn like every member with geometry z ∈ [-silldepth, 0], then
        # positioned at z = +silldepth so it ends up in front of the face.
        sill = Builder.box_child(model, defn, 'PF_Casement_Sill',
                                 x: 0, y: 0, z: sd, w: w, h: st, d: sd,
                                 material: sill_mat)
        Builder.drive(sill,
                      lenx:   ["#{r}!LenX", w],
                      leny:   ["#{r}!sillthickness", st],
                      lenz:   ["#{r}!silldepth", sd],
                      z:      ["#{r}!silldepth", sd],
                      hidden: ["IF(#{r}!hassill=1,0,1)", 0])

        defn
      end

    end # module CasementWindow
  end # module ParaFrame
end # module Kopji
