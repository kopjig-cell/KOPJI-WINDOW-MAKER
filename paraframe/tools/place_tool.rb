# frozen_string_literal: true

# PlaceTool — places a ParaFrame window or door on a wall face.
#
# Behaviour (Phase 4):
#   * A wireframe ghost of the component follows the cursor, inferring onto
#     faces. Only NEAR-VERTICAL faces are valid targets (you hang windows
#     and doors on walls, not floors).
#   * The ghost is oriented to the face: local X runs horizontally along
#     the wall, local Y points up, local Z points out along the face
#     normal — matching how the components are authored (XY = glue plane).
#   * Windows sit with their base at their `sillheight` above Z = 0 (the
#     wall base); doors sit on the floor (sillheight 0). The ghost is
#     centred horizontally on the cursor.
#   * Click places the instance, glued to the face so the native
#     cut-opening fires on that face (multi-layer cutting is Phase 5).
#   * Type a width, or "width;height" (mm), in the VCB before clicking to
#     override the size; the ghost updates live. Esc cancels / exits.
#
# The tool stays active after a placement so several units can be dropped
# in a row, like the native Component tool.

require 'sketchup.rb'

module Kopji
  module ParaFrame
    class PlaceTool

      # A face counts as "vertical" when its normal is within this angle of
      # horizontal (i.e. the face itself is within ~20° of vertical).
      VERTICAL_TOLERANCE = 20.degrees

      # @param type [Symbol] :window or :door
      def initialize(type)
        @type = type
        @definition = nil
        @ip = Sketchup::InputPoint.new
        @transform = nil       # current valid placement transform, or nil
        @face = nil            # face the ghost is snapped to
        @user_w = nil          # width override in inches (from VCB)
        @user_h = nil          # height override in inches
      end

      # --------------------------------------------------------- lifecycle

      def activate
        model = Sketchup.active_model
        @definition = Generators.definition_for(model, @type)
        @transform = nil
        @face = nil
        update_ui
        model.active_view.invalidate
        puts "[ParaFrame] PlaceTool active for #{@type}: " \
             "definition '#{@definition&.name}'"
      rescue StandardError => e
        # SketchUp swallows exceptions raised in activate and silently
        # drops the tool ("nothing happens"). Surface it instead.
        puts "[ParaFrame] PlaceTool activate failed: #{e.class}: #{e.message}\n" \
             "#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame: could not start the placement tool.\n\n" \
                      "#{e.class}: #{e.message}")
        Sketchup.active_model.select_tool(nil)
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        update_ui
        view.invalidate
      end

      def onCancel(_reason, view)
        # First Esc clears a size override; a second exits the tool.
        if @user_w || @user_h
          @user_w = @user_h = nil
          update_ui
          view.invalidate
        else
          Sketchup.active_model.select_tool(nil)
        end
      end

      # ------------------------------------------------------------- input

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y)
        @face = pick_vertical_face(view, x, y)
        @transform = @face ? placement_transform(@face, @ip.position) : nil
        update_ui
        view.invalidate
      end

      def onLButtonUp(_flags, _x, _y, view)
        return unless @transform && @face

        place_instance(view)
      end

      # Width or "width;height" (also accepts a comma) typed in the VCB.
      def onUserText(text, view)
        parts = text.strip.split(/[;,x]/i).map(&:strip).reject(&:empty?)
        return if parts.empty?

        w = parse_length(parts[0])
        h = parts[1] ? parse_length(parts[1]) : nil
        @user_w = w if w && w > 0
        @user_h = h if h && h > 0
        update_ui
        view.invalidate
      rescue ArgumentError
        UI.beep
      end

      def enableVCB?
        true
      end

      # --------------------------------------------------------------- draw

      def draw(view)
        return unless @transform

        # Ghost = the definition's bounding box, scaled for any size
        # override, drawn as edges at the placement transform.
        view.drawing_color = @face ? 'blue' : 'red'
        view.line_width = 2
        view.line_stipple = ''
        view.draw(GL_LINES, ghost_segments)
      end

      def getExtents
        bb = Geom::BoundingBox.new
        bb.add(ghost_corners) if @transform
        bb
      end

      private

      # ------------------------------------------------------- picking math

      # Returns the near-vertical face under the cursor, or nil.
      def pick_vertical_face(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)
        face = ph.picked_face
        return nil unless face.is_a?(Sketchup::Face)

        # Angle between the face normal and the horizontal plane. A
        # vertical face has a horizontal normal (z ≈ 0).
        vertical = face.normal.angle_between(Z_AXIS)
        # vertical ≈ 90° for a wall; accept within tolerance of 90°.
        return nil if (vertical - 90.degrees).abs > VERTICAL_TOLERANCE

        face
      end

      # Builds the transform that places the component on +face+ at +point+.
      # Local axes: X = horizontal along the wall, Y = up, Z = face normal.
      def placement_transform(face, point)
        n = face.normal
        n = n.reverse if n.z.negative? # keep a consistent outward-ish sense

        # Horizontal direction in the face plane: world-up × normal.
        along = Z_AXIS.cross(n)
        return nil if along.length < 1e-6 # face effectively horizontal

        along.normalize!
        up = n.cross(along)
        up.normalize!

        width = scaled_width
        # Base target point: horizontally under the cursor, vertically at
        # the sill height above Z = 0 (windows) or on the floor (doors).
        base_z = base_height
        origin = Geom::Point3d.new(point.x, point.y, base_z)
        # Centre the component horizontally on the cursor.
        origin = origin.offset(along, -width / 2.0)

        Geom::Transformation.axes(origin, along, up, n)
      end

      # ----------------------------------------------------------- placing

      def place_instance(view)
        model = view.model
        model.start_operation("Place ParaFrame #{@type}", true)
        instance = model.active_entities.add_instance(@definition, @transform)
        DCBridge.mark_paraframe!(instance, @type)
        # Glue to the face so the native single-face cut fires (multi-layer
        # cutting is added in Phase 5, which will observe this instance).
        begin
          instance.glued_to = @face
        rescue StandardError => e
          puts "[ParaFrame] glue failed: #{e.message}"
        end
        model.commit_operation

        # Apply any size override through the proven resize path.
        if @user_w || @user_h
          DCBridge.resize!(instance,
                           lenx: @user_w,
                           leny: @user_h)
        end

        DCBridge.redraw(instance, undo: true)
        view.invalidate
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] placement failed: #{e.class}: #{e.message}"
        UI.messagebox("ParaFrame: placement failed.\n#{e.message}")
      end

      # ------------------------------------------------------------ ghost

      # Local-space size after any VCB override (inches).
      def scaled_width
        @user_w || @definition.bounds.width
      end

      def scaled_height
        @user_h || @definition.bounds.height
      end

      # Base elevation of the component (inches, world Z).
      def base_height
        return 0.0 if @type == :door

        raw = @definition.get_attribute(DCBridge::DICT_DC, 'sillheight')
        raw ? raw.to_f : 900.mm
      end

      # Eight corners of the (possibly overridden) ghost box in world space.
      def ghost_corners
        db = @definition.bounds
        sx = scaled_width  / (db.width.zero?  ? 1.0 : db.width)
        sy = scaled_height / (db.height.zero? ? 1.0 : db.height)
        # Local box: X 0..width, Y 0..height, Z 0..depth (frame back on the
        # glue plane). db.depth is the Z extent (SketchUp: depth = Z).
        w = db.width * sx
        h = db.height * sy
        d = db.depth
        pts = [[0, 0, 0], [w, 0, 0], [w, h, 0], [0, h, 0],
               [0, 0, d], [w, 0, d], [w, h, d], [0, h, d]]
        pts.map { |a| Geom::Point3d.new(*a).transform(@transform) }
      end

      # 12 edges of the ghost box as a flat GL_LINES segment list.
      def ghost_segments
        c = ghost_corners
        edges = [[0, 1], [1, 2], [2, 3], [3, 0], # front (on the wall)
                 [4, 5], [5, 6], [6, 7], [7, 4], # outer
                 [0, 4], [1, 5], [2, 6], [3, 7]] # depth
        edges.flat_map { |a, b| [c[a], c[b]] }
      end

      # --------------------------------------------------------------- ui

      def update_ui
        hint = case
               when @user_w && @user_h
                 "Size #{fmt(@user_w)} × #{fmt(@user_h)} — click a wall to place"
               when @user_w
                 "Width #{fmt(@user_w)} — click a wall to place (type W;H to set both)"
               else
                 'Click a wall face to place; type width or width;height (mm). Esc cancels.'
               end
        Sketchup.set_status_text(hint)
        Sketchup.set_status_text('Width;Height', SB_VCB_LABEL)
        vcb = [fmt(@user_w) || '', fmt(@user_h) || ''].reject(&:empty?).join(';')
        Sketchup.set_status_text(vcb, SB_VCB_VALUE)
      end

      def fmt(inches)
        return nil unless inches

        "#{DCBridge.inch_to_mm(inches).round} mm"
      end

      # Parses a VCB length. A bare number is millimetres (ParaFrame's unit);
      # anything with a unit (e.g. 3', 24") is parsed by SketchUp.
      def parse_length(text)
        if text =~ /\A\s*[\d.]+\s*\z/
          DCBridge.mm_to_inch(text.to_f)
        else
          text.to_l
        end
      end

    end # class PlaceTool
  end # module ParaFrame
end # module Kopji
