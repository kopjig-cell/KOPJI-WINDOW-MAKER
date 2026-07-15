# frozen_string_literal: true

# Generator for the basic single-leaf door.
#
# Same authoring rules as the casement window (see builder.rb): flat XY
# authoring, back faces on the glue plane, one child per member, formulas
# referencing the root by name.
#
#   ┌───────────────────────┐  ← head (between the jambs)
#   │ ┌───────────────────┐ │
#   │ │                   │ │    J = jamb (full height, fixed width)
#   │ J│      leaf        │J │    leaf = door panel, recessed in the
#   │ │                   │ │           frame depth
#   │ └───────────────────┘ │
#   └─┴───────────────────┴─┘    (no bottom rail — doors sit on the floor;
#                                 sillheight input is 0 for placement)
#
# User inputs: lenx/leny (size), framewidth, framedepth, leafthickness.

require 'sketchup.rb'

module Kopji
  module ParaFrame
    module PanelDoor

      # Defaults (mm).
      WIDTH   = 900
      HEIGHT  = 2100
      FRAME_W = 60
      FRAME_D = 100
      LEAF_T  = 40

      module_function

      # Builds the door definition inside +model+ and returns it. Caller
      # is responsible for the surrounding operation.
      def build(model)
        w  = WIDTH.mm
        h  = HEIGHT.mm
        fw = FRAME_W.mm
        fd = FRAME_D.mm
        lt = LEAF_T.mm

        frame_mat = Builder.material(model, 'PF Frame', [235, 232, 225])
        leaf_mat  = Builder.material(model, 'PF Door',  [210, 196, 175])

        defn = Builder.new_root(model, 'PF_PanelDoor', :door)
        r = defn.name

        DCBridge.declare_input(defn, :lenx, w, label: 'LenX', formlabel: 'Width')
        DCBridge.declare_input(defn, :leny, h, label: 'LenY', formlabel: 'Height')
        DCBridge.declare_input(defn, :framewidth, fw, formlabel: 'Frame Width')
        DCBridge.declare_input(defn, :framedepth, fd, formlabel: 'Frame Depth')
        DCBridge.declare_input(defn, :leafthickness, lt, formlabel: 'Leaf Thickness')
        # Doors are placed with their base on the floor; hidden from the
        # native Options dialog (placement-tool input only).
        DCBridge.declare_input(defn, :sillheight, 0.0, access: nil)
        DCBridge.declare_input(defn, :revealdepth, 50.mm,
                               formlabel: 'Reveal Depth (placement)')

        # --- frame: two full-height jambs + head ----------------------------
        jamb_l = Builder.box_child(model, defn, 'PF_Door_JambL',
                                   x: 0, y: 0, w: fw, h: h, d: fd, material: frame_mat)
        Builder.drive(jamb_l,
                      lenx: ["#{r}!framewidth", fw],
                      leny: ["#{r}!LenY", h],
                      lenz: ["#{r}!framedepth", fd])

        jamb_r = Builder.box_child(model, defn, 'PF_Door_JambR',
                                   x: w - fw, y: 0, w: fw, h: h, d: fd, material: frame_mat)
        Builder.drive(jamb_r,
                      lenx: ["#{r}!framewidth", fw],
                      leny: ["#{r}!LenY", h],
                      lenz: ["#{r}!framedepth", fd],
                      x:    ["#{r}!LenX-#{r}!framewidth", w - fw])

        head = Builder.box_child(model, defn, 'PF_Door_Head',
                                 x: fw, y: h - fw, w: w - 2 * fw, h: fw, d: fd,
                                 material: frame_mat)
        Builder.drive(head,
                      lenx: ["#{r}!LenX-2*#{r}!framewidth", w - 2 * fw],
                      leny: ["#{r}!framewidth", fw],
                      lenz: ["#{r}!framedepth", fd],
                      x:    ["#{r}!framewidth", fw],
                      y:    ["#{r}!LenY-#{r}!framewidth", h - fw])

        # --- leaf: fills the frame, centred in the frame depth ---------------
        leaf = Builder.box_child(model, defn, 'PF_Door_Leaf',
                                 x: fw, y: 0, z: -(fd - lt) / 2.0,
                                 w: w - 2 * fw, h: h - fw, d: lt,
                                 material: leaf_mat)
        Builder.drive(leaf,
                      lenx: ["#{r}!LenX-2*#{r}!framewidth", w - 2 * fw],
                      leny: ["#{r}!LenY-#{r}!framewidth", h - fw],
                      lenz: ["#{r}!leafthickness", lt],
                      x:    ["#{r}!framewidth", fw],
                      z:    ["-(#{r}!framedepth-#{r}!leafthickness)/2", -(fd - lt) / 2.0])

        defn
      end

    end # module PanelDoor
  end # module ParaFrame
end # module Kopji
