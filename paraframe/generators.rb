# frozen_string_literal: true

# Top-level generator entry: builds the bundled parametric components in
# the live model, places preview instances, and saves each definition to
# paraframe/components/**.skp so the library (Phase 8) and placement tool
# (Phase 4) can load them.
#
# Run from Extensions → ParaFrame → Generate Components (dev). Generation
# happens on a real SketchUp — the .skp files are produced on the dev
# machine and then shipped inside the .rbz.

require 'sketchup.rb'
require 'fileutils'

require File.join(File.dirname(__FILE__), 'generators', 'builder')
require File.join(File.dirname(__FILE__), 'generators', 'casement_window')
require File.join(File.dirname(__FILE__), 'generators', 'panel_door')

module Kopji
  module ParaFrame
    module Generators

      # Base definition names, keyed by ParaFrame type.
      BASE_NAMES = { window: 'PF_Casement', door: 'PF_PanelDoor' }.freeze

      module_function

      # Returns a definition for +type+ (:window/:door) to place, reusing
      # one already in the model when possible, otherwise building it.
      # Prefers a bundled .skp (shipped in the .rbz) so placements match
      # the library thumbnails; falls back to generating in-model.
      def definition_for(model, type)
        base = BASE_NAMES.fetch(type)
        existing = model.definitions[base]
        existing ||= model.definitions.to_a.find do |d|
          d.name.start_with?(base) && DCBridge.paraframe_type(d) == type.to_s
        end
        return existing if existing

        rel = type == :window ? File.join('windows', 'casement_basic.skp')
                              : File.join('doors', 'door_single.skp')
        skp = File.join(PATH, 'components', rel)
        if File.exist?(skp)
          begin
            return model.definitions.load(skp)
          rescue StandardError => e
            puts "[ParaFrame] could not load #{skp}: #{e.message}; building instead"
          end
        end

        # Build in its own operation so the fresh geometry is a clean,
        # undoable transaction rather than loose edits during tool activate.
        model.start_operation("ParaFrame: build #{type}", true)
        defn = type == :window ? CasementWindow.build(model) : PanelDoor.build(model)
        model.commit_operation
        defn
      rescue StandardError => e
        model.abort_operation rescue nil
        raise e
      end

      # Builds window + door, drops preview instances standing upright at
      # the origin, and saves the .skp files. One undo step for the model
      # changes (file writes are not undoable, of course).
      def generate_all(model = Sketchup.active_model)
        return false unless DCBridge.ensure_dc!

        model.start_operation('ParaFrame: Generate Components', true)
        window_defn = CasementWindow.build(model)
        door_defn   = PanelDoor.build(model)

        # Components are authored flat (XY = glue plane); stand the
        # previews upright (rotate +90° about X: local +Y → world +Z) so
        # they read as a window and a door in the model.
        upright = Geom::Transformation.rotation(
          Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(1, 0, 0), 90.degrees
        )
        window_inst = model.active_entities.add_instance(
          window_defn, Geom::Transformation.new(Geom::Point3d.new(0, 0, 0)) * upright
        )
        door_inst = model.active_entities.add_instance(
          door_defn, Geom::Transformation.new(Geom::Point3d.new(1800.mm, 0, 0)) * upright
        )
        DCBridge.mark_paraframe!(window_inst, :window)
        DCBridge.mark_paraframe!(door_inst, :door)

        # First redraw inside the same operation: evaluates every formula
        # once so seeds settle and copies/hidden states materialise.
        DCBridge.redraw(window_inst)
        DCBridge.redraw(door_inst)
        model.commit_operation

        saved = save_definitions(window_defn => File.join('windows', 'casement_basic.skp'),
                                 door_defn => File.join('doors', 'door_single.skp'))

        UI.messagebox(
          "ParaFrame components generated.\n\n" \
          "Preview instances placed at the origin (window) and 1.8 m to " \
          "the right (door).\n\n#{saved.join("\n")}"
        )
        true
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] generate_all failed: #{e.class}: #{e.message}\n" \
             "#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame: component generation failed.\n#{e.message}")
        false
      end

      # Saves each definition under paraframe/components/. Returns report
      # lines; failures are reported but don't raise (the in-model preview
      # is still useful without the files).
      def save_definitions(mapping)
        mapping.map do |defn, rel_path|
          path = File.join(PATH, 'components', rel_path)
          FileUtils.mkdir_p(File.dirname(path))
          if defn.save_as(path)
            "saved: #{path}"
          else
            "SAVE FAILED: #{path}"
          end
        rescue StandardError => e
          "SAVE FAILED: #{path} (#{e.class}: #{e.message})"
        end
      end

    end # module Generators
  end # module ParaFrame
end # module Kopji
