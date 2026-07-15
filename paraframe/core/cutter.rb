# frozen_string_literal: true

# Cutter — ParaFrame's multi-layer wall-cutting engine.
#
# The native Dynamic Components cut-opening only cuts the single face a
# component is glued to, and only when that face is a loose face in the same
# drawing context. Real walls are grouped, layered (block + plaster skins),
# or cavity constructions (two parallel leaves). This engine cuts a clean
# rectangular opening through EVERY wall layer behind the component, records
# what it did, and can heal the wall back to solid when the component is
# moved or deleted.
#
# How layers are found (v2 — face collection, not ray marching)
# -------------------------------------------------------------
# A ParaFrame component is authored flat: local Z is the outward wall
# normal, the local Z = 0 plane (the "glue plane") sits on the wall face,
# and the opening is the LenX × LenY rectangle on that plane extruded along
# -Z into the wall, to at most the configured cut depth.
#
# Ray marching (v1) failed on real walls: coincident faces where a plaster
# skin touches the block get skipped by the ray's step-over, and cavity
# leaves confused hit pairing. Instead we now treat every drawing context
# independently:
#
#   * candidates = the model's loose geometry + every top-level group /
#     component whose bounds intersect the opening's swept box (excluding
#     ParaFrame components themselves),
#   * shared-definition containers are made unique first — cutting a copied
#     wall group must not edit its siblings (this was eating whole faces:
#     two leaves of a cavity wall sharing a definition each got both cuts),
#   * within one context, every face parallel to the glue plane that
#     overlaps the opening rectangle and lies within the cut depth is a
#     layer boundary; sorted by depth, each consecutive pair bounds one
#     slab of wall,
#   * each slab gets the opening punched through both bounding faces and
#     four reveal faces lining the hole, in the wall's material.
#
# Heal records (per slab: container persistent-id path, front/back opening
# quads in world space, material name) are stored as JSON in the instance's
# "ParaFrame" dictionary. cut / heal / recut each run inside one model
# operation and roll back with abort_operation on failure.

require 'sketchup.rb'
require 'json'

module Kopji
  module ParaFrame
    module Cutter

      # Key in the "ParaFrame" dictionary holding the JSON cut record.
      KEY_CUT = 'cut_record'

      # Numeric slop for coplanar / point-match tests (inches).
      EPS = 0.001

      # Minimum distinct slab thickness / depth separation (inches, ~0.5 mm).
      SLAB_MIN = 0.02

      module_function

      # ------------------------------------------------------------- public

      # Cuts the opening for +instance+ through every wall layer behind its
      # glue plane. Stores a cut record. Returns true on success.
      def cut(instance)
        return false unless DCBridge.paraframe_component?(instance)

        model = instance.model
        model.start_operation('ParaFrame Cut', true)
        corners, normal = opening_world(instance)
        depth = Settings.cut_depth
        # Components sit back from the facade by their reveal depth, so the
        # wall's OUTER face lies in front of the glue plane (negative
        # depth). Reach back that far (plus slop) when hunting for faces.
        back = DCBridge.get_attr(instance, :revealdepth, 0).to_f + 1.mm
        records = []
        collect_targets(model, instance, corners, normal, depth, back).each do |ents, tr, ids|
          faces = matching_faces(ents, tr, corners, normal, depth, back)
          pair_faces(faces).each do |(front_face, d0), (_back_face, d1)|
            records << cut_slab(ents, tr, ids, front_face, d0, d1, corners, normal)
          end
        end
        store_record(instance, records.compact)
        model.commit_operation
        # Track the instance so move/scale/erase keep the opening in sync.
        Observers.watch(instance) if defined?(Observers)
        true
      rescue StandardError => e
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

        heal_records(instance.model, record, -> { clear_record(instance) })
      end

      # Heals from record data directly — used by the observers to heal
      # the wall after the instance itself has been erased (its dictionary
      # goes with it, so the observers keep a cached copy). +extra+ runs
      # inside the same operation (e.g. clearing the record attribute).
      def heal_records(model, records, extra = nil)
        return true if records.nil? || records.empty?

        model.start_operation('ParaFrame Heal', true)
        records.each { |layer| heal_layer(model, layer) }
        extra&.call
        model.commit_operation
        true
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] heal failed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame: wall heal failed and was rolled back.\n#{e.message}")
        false
      end

      # Heal + cut: used after a move or resize so the opening tracks the
      # component.
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

      # The opening corners pushed +d+ into the wall (world space).
      def project_depth(corners, normal, d)
        corners.map { |p| p.offset(normal, -d) }
      end

      # ------------------------------------------------------ target finder

      # Drawing contexts that may contain wall layers: the model's loose
      # geometry plus every top-level group/component instance overlapping
      # the opening's swept box. Shared definitions are made unique so a
      # cut never bleeds into sibling copies. Returns
      # [[entities, to_world_transform, persistent_id_path], ...].
      def collect_targets(model, skip_instance, corners, normal, depth, back = 0)
        targets = [[model.entities, Geom::Transformation.new, []]]
        model.entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if e.equal?(skip_instance)
          next if DCBridge.paraframe_component?(e)
          next unless bounds_overlap?(e.bounds, corners, normal, depth, back)

          e.make_unique if e.definition.count_instances > 1
          targets << [e.definition.entities, e.transformation, [e.persistent_id]]
        end
        targets
      end

      # Does +bounds+ intersect the box swept by the opening from +back+ in
      # front of the glue plane to +depth+ behind it?
      def bounds_overlap?(bounds, corners, normal, depth, back = 0)
        swept = Geom::BoundingBox.new
        corners.each do |p|
          swept.add(p.offset(normal, back)) if back > 0
          swept.add(p)
          swept.add(p.offset(normal, -depth))
        end
        inter = bounds.intersect(swept)
        inter.valid? && inter.diagonal > EPS
      end

      # ------------------------------------------------------- layer finder

      # Faces of one context that are parallel to the glue plane, overlap
      # the opening rectangle, and lie within the cut depth — i.e. the
      # layer boundaries the opening must punch through. Returns
      # [[face, depth], ...] sorted front to back.
      def matching_faces(ents, tr, corners, normal, max_depth, back = 0)
        ti = tr.inverse
        lc = corners.map { |p| p.transform(ti) }
        ln = normal.clone.transform(ti)
        ln.normalize!
        origin = lc[0]
        xaxis = origin.vector_to(lc[1])
        w = xaxis.length
        xaxis.normalize!
        yaxis = origin.vector_to(lc[3])
        h = yaxis.length
        yaxis.normalize!
        into = ln.reverse
        margin = 1.mm

        found = ents.grep(Sketchup::Face).filter_map do |face|
          next unless face.normal.parallel?(ln)

          # Depth of the face plane measured from the glue plane into the
          # wall (all face vertices are coplanar; the first will do).
          # Negative depths reach back to the facade in front of a
          # recessed (revealdepth) glue plane.
          d = origin.vector_to(face.vertices.first.position) % into
          next unless d > -(back + margin) && d <= max_depth

          # 2D overlap: the face's extent along the opening's in-plane axes
          # must overlap the opening rectangle [0,w] × [0,h].
          xs = face.vertices.map { |v| origin.vector_to(v.position) % xaxis }
          ys = face.vertices.map { |v| origin.vector_to(v.position) % yaxis }
          next unless xs.min < w - margin && xs.max > margin &&
                      ys.min < h - margin && ys.max > margin

          [face, d]
        end
        dedupe_by_depth(found.sort_by { |(_f, d)| d })
      end

      # Keeps one boundary face per distinct depth plane. Two coplanar
      # faces at the same depth (a common result of prior cuts or touching
      # skins) would otherwise pair into a zero-thickness slab whose reveal
      # quads collapse to duplicate points — the "Duplicate points in
      # array" cut failure.
      def dedupe_by_depth(faces)
        kept = []
        faces.each do |face, d|
          kept << [face, d] unless kept.any? { |(_f, dk)| (dk - d).abs < SLAB_MIN }
        end
        kept
      end

      # Consecutive depth-sorted boundary faces bound one slab each:
      # n faces → n-1 slabs. (A plain wall: front+back → 1 slab. A block
      # with internal partitions: every gap gets punched and lined, so the
      # opening reads as a continuous lined tunnel.) Zero/near-zero
      # thickness pairs are dropped defensively.
      def pair_faces(faces)
        faces.each_cons(2).reject { |(_f0, d0), (_f1, d1)| (d1 - d0).abs < SLAB_MIN }
      end

      # --------------------------------------------------------- cut a slab

      # Punches the opening through the two boundary planes of one slab and
      # lines the hole with reveal faces. Returns the heal record.
      def cut_slab(ents, tr, ids, front_face, d0, d1, corners, normal)
        material = wall_material(front_face)
        front_w = project_depth(corners, normal, d0)
        back_w  = project_depth(corners, normal, d1)
        ti = tr.inverse
        front_l = front_w.map { |p| p.transform(ti) }
        back_l  = back_w.map  { |p| p.transform(ti) }

        punch(ents, front_l)
        punch(ents, back_l)
        add_reveals(ents, front_l, back_l, material)

        {
          'container' => ids,
          'front'     => front_w.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] },
          'back'      => back_w.map  { |p| [p.x.to_f, p.y.to_f, p.z.to_f] },
          'material'  => material&.name
        }
      end

      # Splits the coplanar wall face with +quad+ and erases the interior,
      # leaving a hole bounded by the quad edges. Safety: only erase when
      # the face we got back is quad-sized — erasing a merged/outer face
      # would remove the wall itself.
      def punch(ents, quad)
        face = safe_add_face(ents, quad)
        return unless face

        # add_face usually returns the small inner opening, but sometimes
        # the surrounding wall face instead. Erase the opening-sized face —
        # never the big one — so we make a hole without deleting the wall.
        if opening_sized?(face, quad)
          face.erase!
        else
          inner = face.edges.flat_map(&:faces).uniq
                      .find { |f| f != face && opening_sized?(f, quad) }
          inner&.erase!
        end
      end

      # True when +face+'s area is within 5% of the opening quad's area.
      def opening_sized?(face, quad)
        return false unless face&.valid?

        expected = quad_area(quad)
        (face.area - expected).abs <= expected * 0.05
      end

      # Area of a planar quad (two triangles).
      def quad_area(quad)
        a = (quad[1] - quad[0]).cross(quad[3] - quad[0]).length / 2.0
        b = (quad[1] - quad[2]).cross(quad[3] - quad[2]).length / 2.0
        a + b
      end

      # Adds the four reveal (jamb/head/sill) faces connecting the front
      # opening to the back opening, tinted with the wall material.
      def add_reveals(ents, front, back, material)
        4.times do |k|
          a = front[k]
          b = front[(k + 1) % 4]
          c = back[(k + 1) % 4]
          d = back[k]
          face = safe_add_face(ents, [a, b, c, d])
          next unless face && material

          face.material = material
          face.back_material = material
        end
      end

      # -------------------------------------------------------- heal a slab

      def heal_layer(model, layer)
        ents, tr = resolve_container_by_ids(model, layer['container'])
        unless ents
          puts "[ParaFrame] heal: container #{layer['container'].inspect} not found"
          return
        end

        ti = tr.inverse
        front = layer['front'].map { |a| Geom::Point3d.new(*a).transform(ti) }
        back  = layer['back'].map  { |a| Geom::Point3d.new(*a).transform(ti) }
        material = model.materials[layer['material']] if layer['material']

        # Delete the four reveal faces, then refill the two openings.
        reveals = 0
        4.times do |k|
          quad = [front[k], front[(k + 1) % 4], back[(k + 1) % 4], back[k]]
          f = find_face(ents, quad)
          next unless f

          f.erase!
          reveals += 1
        end
        filled = 0
        merged = 0
        [front, back].each do |quad|
          face = safe_add_face(ents, quad)
          next unless face

          filled += 1
          if material
            face.material = material
            face.back_material = material
          end
          # Dissolve the patch outline using THIS face's own boundary edges
          # (no coordinate lookup — that drifted past tolerance and merged
          # nothing). Erasing the edges that separate the patch from the
          # coplanar wall merges them into one clean face.
          boundary = face.edges.select do |e|
            fs = e.faces
            fs.length == 2 && fs[0].normal.parallel?(fs[1].normal)
          end
          merged += boundary.length
          ents.erase_entities(boundary) unless boundary.empty?
        end
        removed = remove_faceless(ents, front + back)
        puts "[ParaFrame] heal layer: reveals #{reveals}/4, refilled " \
             "#{filled}/2, outline merged #{merged}, stray edges #{removed}"
      end

      # Removes faceless edges (leftover reveal corners) whose endpoints are
      # among the opening corners. Returns how many were removed.
      def remove_faceless(ents, corners)
        stray = ents.grep(Sketchup::Edge).select do |e|
          e.valid? && e.faces.empty? &&
            near_any?(e.start.position, corners) &&
            near_any?(e.end.position, corners)
        end
        ents.erase_entities(stray) unless stray.empty?
        stray.length
      end

      def near_any?(point, corners)
        corners.any? { |c| coincident?(point, c) }
      end

      # ----------------------------------------------------- container paths

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
        raw = raw_record(instance)
        raw ? JSON.parse(raw) : nil
      rescue JSON::ParserError
        nil
      end

      # The record as its raw JSON string (for the observers' cache).
      def raw_record(instance)
        instance.get_attribute(DCBridge::DICT_PF, KEY_CUT)
      end

      def clear_record(instance)
        dict = instance.attribute_dictionary(DCBridge::DICT_PF, false)
        dict&.delete_key(KEY_CUT)
      end

      # ------------------------------------------------------------- helpers

      def wall_material(face)
        return nil unless face.is_a?(Sketchup::Face)

        face.material || face.back_material
      end

      # add_face that never raises on degenerate input: coincident
      # consecutive points are dropped, and a loop with fewer than three
      # distinct points is skipped (returns nil) instead of throwing
      # "Duplicate points in array" and rolling back the whole cut.
      def safe_add_face(ents, points)
        clean = []
        points.each do |p|
          prev = clean.last || points.last
          clean << p unless coincident?(p, prev)
        end
        return nil if clean.length < 3

        ents.add_face(clean)
      rescue ArgumentError => e
        puts "[ParaFrame] safe_add_face skipped: #{e.message}"
        nil
      end

      def coincident?(a, b)
        (a.x - b.x).abs < EPS && (a.y - b.y).abs < EPS && (a.z - b.z).abs < EPS
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
