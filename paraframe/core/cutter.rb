# frozen_string_literal: true

# Cutter — ParaFrame's multi-layer wall-cutting engine.
#
# The native Dynamic Components cut-opening only cuts the single face a
# component is glued to, and only when that face is a loose face in the same
# drawing context. Real walls are grouped, layered (block + plaster skins),
# or cavity constructions (two parallel leaves). This engine cuts a clean
# rectangular opening through EVERY solid layer the component passes into,
# records what it did, and can heal the wall back to solid when the
# component is moved or deleted.
#
# Geometry model
# --------------
# A ParaFrame component is authored flat: its local Z axis is the outward
# wall normal, and its local Z = 0 plane (the "glue plane") sits on the wall
# face. The opening is the LenX x LenY rectangle on that plane, extruded
# along -Z (into the wall). We march a ray from just outside the glue plane
# straight into the wall and collect the faces it pierces; each consecutive
# pair of hits (enter, exit) is one solid layer. For each layer we punch the
# opening through its front and back faces and add the four reveal faces
# that line the hole.
#
# Everything a cut touched is recorded (per layer: the container path by
# persistent id, the front and back opening rectangles, the wall material)
# so heal can refill the faces and delete the reveals.
#
# All of cut / heal / recut run inside a single model operation and roll
# back with abort_operation on any failure.

require 'sketchup.rb'
require 'json'

module Kopji
  module ParaFrame
    module Cutter

      # Key in the "ParaFrame" dictionary holding the JSON cut record.
      KEY_CUT = 'cut_record'

      # Numeric slop for coplanar / point-match tests (inches).
      EPS = 0.001

      module_function

      # ------------------------------------------------------------- public

      # Cuts the opening for +instance+ through every solid layer behind its
      # glue plane. Stores a cut record. Returns true on success.
      def cut(instance)
        return false unless DCBridge.paraframe_component?(instance)

        model = instance.model
        model.start_operation('ParaFrame Cut', true)
        corners, normal = opening_world(instance)
        # Hide the component during the scan so the ray finds WALL faces,
        # not the window's own flush-mounted frame and glass (which the DC
        # engine would then invalidate mid-cut → "deleted DrawingElement").
        instance.hidden = true
        layers = scan_layers(model, corners, normal, Settings.cut_depth)
        instance.hidden = false
        records = layers.filter_map do |layer|
          cut_layer(model, layer, corners, normal)
        end
        store_record(instance, records)
        model.commit_operation
        true
      rescue StandardError => e
        instance.hidden = false if instance.respond_to?(:hidden=) && instance.valid?
        model.abort_operation rescue nil
        puts "[ParaFrame] cut failed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame: wall cut failed and was rolled back.\n#{e.message}")
        false
      end

      # Refills every face a previous cut removed and deletes the reveals,
      # returning the walls to solid. Clears the cut record. Returns true
      # on success (or when there was nothing to heal).
      def heal(instance)
        record = load_record(instance)
        return true if record.nil? || record.empty?

        model = instance.model
        model.start_operation('ParaFrame Heal', true)
        record.each { |layer| heal_layer(model, layer) }
        clear_record(instance)
        model.commit_operation
        true
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] heal failed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame: wall heal failed and was rolled back.\n#{e.message}")
        false
      end

      # Heal + cut: used after a move or resize so the opening tracks the
      # component. One combined operation would be ideal, but heal and cut
      # each need their own commit for the DC/undo bookkeeping to settle, so
      # this is two undo steps.
      def recut(instance)
        heal(instance) && cut(instance)
      end

      # True when a cut record is present on the instance.
      def cut?(instance)
        rec = load_record(instance)
        !(rec.nil? || rec.empty?)
      end

      # ------------------------------------------------------- opening math

      # The four world-space corners of the opening (on the glue plane) and
      # the outward wall normal. Size is read from live geometry the same
      # way resize! measures it, minus the reveal inset.
      def opening_world(instance)
        t  = instance.transformation
        db = instance.definition.bounds
        # SketchUp BoundingBox: width = X, height = Y, depth = Z.
        w = db.width  * t.xaxis.length
        h = db.height * t.yaxis.length
        inset = Settings.reveal
        x0 = inset
        y0 = inset
        x1 = w - inset
        y1 = h - inset
        corners = [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
                  .map { |a| Geom::Point3d.new(*a).transform(t) }
        [corners, t.zaxis.normalize]
      end

      # ------------------------------------------------------- layer finder

      # Marches a ray from just outside the glue plane straight into the
      # wall, collecting pierced faces up to +max_depth+. Returns an array
      # of layers, each [front_hit, front_path, back_hit, back_path], where
      # a *_path is the Sketchup raytest path (container instances + face).
      def scan_layers(model, corners, normal, max_depth)
        center = centroid(corners)
        into = normal.reverse
        start = center.offset(normal, 2.mm) # begin just outside the wall
        hits = []
        probe = start
        50.times do
          # wysiwyg = true so hidden geometry (the component we're cutting
          # for) is skipped by the ray.
          res = model.raytest([probe, into], true)
          break unless res

          point, path = res
          depth = (center - point) % normal # distance travelled into the wall
          break if depth > max_depth + 2.mm
          # Always step past this face so the loop can't stall.
          probe = point.offset(into, 0.2.mm)
          face = path.last
          next unless face.is_a?(Sketchup::Face)
          # Ignore any other ParaFrame component the ray grazes.
          next if path.any? do |e|
            e.respond_to?(:get_attribute) && DCBridge.paraframe_component?(e)
          end

          # facing < 0 → the ray enters a solid here (front face);
          # facing > 0 → the ray exits a solid here (back face). Comparing
          # the world-space face normal to the ray direction is robust for
          # cavity/layered walls, where naive pair-by-two mis-groups leaves.
          facing = world_normal(face, path) % into
          hits << { point: point, path: path, facing: facing }
        end

        pair_layers(hits)
      end

      # Pairs each entering face with the next exiting face into solid
      # layers: [front_pt, front_path, back_pt, back_path].
      def pair_layers(hits)
        layers = []
        i = 0
        while i < hits.length
          unless hits[i][:facing] < 0 # not an entry face; skip
            i += 1
            next
          end

          j = i + 1
          j += 1 while j < hits.length && hits[j][:facing] < 0 # next exit
          break if j >= hits.length

          layers << [hits[i][:point], hits[i][:path], hits[j][:point], hits[j][:path]]
          i = j + 1
        end
        layers
      end

      # World-space normal of a face given its raytest path (container
      # instances precede the face). Rigid container transforms only, which
      # is the norm for walls.
      def world_normal(face, path)
        tr = Geom::Transformation.new
        path[0...-1].each do |e|
          tr *= e.transformation if e.respond_to?(:transformation)
        end
        face.normal.transform(tr).normalize
      end

      # --------------------------------------------------------- cut a layer

      # Cuts the opening through one solid layer. Returns the heal record
      # for that layer, or nil if it could not be cut.
      def cut_layer(model, layer, corners, normal)
        front_pt, front_path, back_pt, _back_path = layer
        ents, tr, container_ids = resolve_container(model, front_path)
        return nil unless ents

        # Project the glue-plane opening onto the layer's front and back
        # face planes (both perpendicular to the normal for a flat wall).
        front_w = project(corners, normal, front_pt)
        back_w  = project(corners, normal, back_pt)

        material = wall_material(front_path.last)

        ti = tr.inverse
        front_l = front_w.map { |p| p.transform(ti) }
        back_l  = back_w.map  { |p| p.transform(ti) }

        punch(ents, front_l)
        punch(ents, back_l)
        add_reveals(ents, front_l, back_l, material)

        {
          'container' => container_ids,
          'front'     => front_w.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] },
          'back'      => back_w.map  { |p| [p.x.to_f, p.y.to_f, p.z.to_f] },
          'material'  => material&.name
        }
      end

      # Splits the coplanar wall face with +quad+ and erases the interior,
      # leaving a hole bounded by the quad edges.
      def punch(ents, quad)
        face = ents.add_face(quad)
        face&.erase!
      end

      # Adds the four reveal (jamb/head/sill) faces connecting the front
      # opening to the back opening, tinted with the wall material.
      def add_reveals(ents, front, back, material)
        4.times do |k|
          a = front[k]
          b = front[(k + 1) % 4]
          c = back[(k + 1) % 4]
          d = back[k]
          face = ents.add_face(a, b, c, d)
          next unless face && material

          face.material = material
          face.back_material = material
        end
      end

      # -------------------------------------------------------- heal a layer

      def heal_layer(model, layer)
        ents, tr = resolve_container_by_ids(model, layer['container'])
        return unless ents

        ti = tr.inverse
        front = layer['front'].map { |a| Geom::Point3d.new(*a).transform(ti) }
        back  = layer['back'].map  { |a| Geom::Point3d.new(*a).transform(ti) }
        material = model.materials[layer['material']] if layer['material']

        # Delete the four reveal faces, then refill the front and back holes.
        4.times do |k|
          quad = [front[k], front[(k + 1) % 4], back[(k + 1) % 4], back[k]]
          f = find_face(ents, quad)
          f&.erase!
        end
        [front, back].each do |quad|
          face = ents.add_face(quad)
          if face && material
            face.material = material
            face.back_material = material
          end
        end
      end

      # ----------------------------------------------------- container paths

      # Resolves a raytest path to the drawing context to cut in: the
      # entities collection, its local-to-world transform, and the
      # persistent-id list of the container instances (for healing later).
      def resolve_container(model, path)
        instances = path[0...-1].select do |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        end
        tr = Geom::Transformation.new
        ents = model.entities
        ids = []
        instances.each do |inst|
          tr *= inst.transformation
          ents = inst.definition.entities
          ids << inst.persistent_id
        end
        [ents, tr, ids]
      end

      # Rebuilds [entities, transform] from a stored persistent-id list.
      def resolve_container_by_ids(model, ids)
        tr = Geom::Transformation.new
        ents = model.entities
        (ids || []).each do |id|
          inst = model.find_entity_by_persistent_id(id)
          return [nil, nil] unless inst.respond_to?(:definition)

          tr *= inst.transformation
          ents = inst.definition.entities
        end
        [ents, tr]
      end

      # -------------------------------------------------------- cut records

      def store_record(instance, records)
        instance.set_attribute(DCBridge::DICT_PF, KEY_CUT, JSON.generate(records))
      end

      def load_record(instance)
        raw = instance.get_attribute(DCBridge::DICT_PF, KEY_CUT)
        raw ? JSON.parse(raw) : nil
      rescue JSON::ParserError
        nil
      end

      def clear_record(instance)
        dict = instance.attribute_dictionary(DCBridge::DICT_PF, false)
        dict&.delete_key(KEY_CUT)
      end

      # ------------------------------------------------------------- helpers

      def centroid(points)
        n = points.length.to_f
        Geom::Point3d.new(points.sum(&:x) / n, points.sum(&:y) / n,
                          points.sum(&:z) / n)
      end

      # Projects each point onto the plane through +plane_pt+ with the given
      # normal, moving along the normal (opening axis).
      def project(points, normal, plane_pt)
        points.map do |p|
          d = (p - plane_pt) % normal
          p.offset(normal, -d)
        end
      end

      def wall_material(face)
        return nil unless face.is_a?(Sketchup::Face)

        face.material || face.back_material
      end

      # Finds a face in +ents+ whose vertices match the given points (any
      # order / winding), or nil.
      def find_face(ents, points)
        want = points.map { |p| [p.x, p.y, p.z] }
        ents.grep(Sketchup::Face).find do |f|
          vs = f.vertices
          next false unless vs.length == points.length

          got = vs.map { |v| [v.position.x, v.position.y, v.position.z] }
          want.all? { |w| got.any? { |g| pt_eq(w, g) } }
        end
      end

      def pt_eq(a, b)
        (a[0] - b[0]).abs < EPS && (a[1] - b[1]).abs < EPS && (a[2] - b[2]).abs < EPS
      end

    end # module Cutter
  end # module ParaFrame
end # module Kopji
