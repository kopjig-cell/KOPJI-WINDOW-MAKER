# frozen_string_literal: true

# Shared low-level helpers for the ParaFrame component generators.
#
# Every ParaFrame component follows the same anatomy, dictated by how the
# DC engine and the glue/cut behaviors actually work (established in
# Phase 2 against a live SketchUp):
#
#  * The root definition is authored FLAT: X = width, Y = height,
#    Z = depth. Gluing rotates the XY plane onto the wall face, so when a
#    window hangs on a wall its local +Y points up the wall and +Z points
#    out of the wall. The native cut-opening outline is taken from edges
#    lying ON the z=0 plane — which is why every solid member keeps its
#    back face exactly at z=0 (geometry spans z ∈ [-depth, 0]).
#  * Nothing parametric lives in loose geometry: each member is a CHILD
#    component whose size/position is driven by formulas referencing the
#    root definition BY NAME (e.g. "PF_Casement!LenX"). The engine reads
#    root LenX/LenY/LenZ from LIVE geometry, so width/height changes go
#    through DCBridge.resize! (scale, then redraw) — exactly like the
#    native Options dialog.
#  * Each child gets its own definition (DC formulas live on the child's
#    definition, so shared definitions would share formulas).

require 'sketchup.rb'

module Kopji
  module ParaFrame
    module Builder

      module_function

      # Finds-or-creates a material; +rgb+ is [r,g,b] 0..255, +alpha+ < 1
      # makes it translucent (glass).
      def material(model, name, rgb, alpha = 1.0)
        m = model.materials[name] || model.materials.add(name)
        m.color = Sketchup::Color.new(*rgb)
        m.alpha = alpha
        m
      end

      # Creates the root definition of a ParaFrame component with the
      # glue-to-vertical and cut-opening behaviors, its DC dictionary
      # stamps, and the ParaFrame type marker ("window"/"door").
      def new_root(model, name, type)
        defn = model.definitions.add(name)
        behavior = defn.behavior
        behavior.is2d = true              # gluing component (XY = glue plane)
        behavior.snapto = SnapTo_Vertical # only glue to near-vertical faces
        behavior.cuts_opening = true      # native cut of the glued face
        DCBridge.init_dc_dict!(defn, defn.name)
        defn.set_attribute(DCBridge::DICT_PF, DCBridge::KEY_TYPE, type.to_s)
        defn
      end

      # Adds one box-shaped child component to +parent_defn+.
      #
      # The box spans x 0..w, y 0..h, z -d..0 in the CHILD's own
      # coordinates — back face on the glue plane — and the child instance
      # is placed at [x, y, z] in the parent. Returns the child instance.
      def box_child(model, parent_defn, name, x:, y:, w:, h:, d:, z: 0, material: nil)
        cd = model.definitions.add(name)
        face = cd.entities.add_face([0, 0, 0], [w, 0, 0], [w, h, 0], [0, h, 0])
        # Push-pull away from +Z so the geometry lands in z ∈ [-d, 0]
        # regardless of which way SketchUp oriented the new face.
        face.pushpull(face.normal.z > 0 ? -d : d)
        if material
          cd.entities.grep(Sketchup::Face).each do |f|
            f.material = material
            f.back_material = material
          end
        end
        inst = parent_defn.entities.add_instance(
          cd, Geom::Transformation.new(Geom::Point3d.new(x, y, z))
        )
        DCBridge.init_dc_dict!(cd, cd.name)
        DCBridge.init_dc_dict!(inst, cd.name)
        inst
      end

      # Declares a set of driving formulas on a child in one call.
      # +formulas+ maps attribute => [formula_string, seed] where seed is
      # the child's current drawn value (the engine overwrites it on the
      # first redraw; a close seed avoids a visible jump).
      #
      #   drive(jamb, lenx: ["#{r}!framewidth", fw], x: ["#{r}!LenX-...", x0])
      def drive(child, formulas)
        formulas.each do |key, (formula, seed)|
          DCBridge.declare_child_formula(child, key, formula, seed: seed || 0.0)
        end
        child
      end

    end # module Builder
  end # module ParaFrame
end # module Kopji
