# frozen_string_literal: true

# ParaFrame — main entry point.
#
# Loaded by the SketchupExtension registered in ../paraframe.rb the first time
# the extension is enabled. Responsible for:
#   * requiring all implementation files (added phase by phase),
#   * building the Extensions > ParaFrame menu,
#   * building the ParaFrame toolbar,
#   * providing the dev-mode `reload` helper.
#
# Phase 1: all five commands are placeholders that pop a messagebox, so the
# menu/toolbar wiring can be verified in SketchUp before any tool logic lands.

require 'sketchup.rb'

module Kopji
  module ParaFrame

    # Absolute path of the paraframe/ support folder (folder of this file).
    # `defined?` guards keep `load`-based reloads from warning about
    # re-assigning frozen constants.
    PATH  = File.dirname(__FILE__).freeze          unless defined?(PATH)
    ICONS = File.join(PATH, 'resources', 'icons').freeze unless defined?(ICONS)

    # --- implementation requires -------------------------------------------
    require File.join(PATH, 'core', 'dc_bridge')
    # Uncommented as each phase lands:
    # require File.join(PATH, 'core',  'settings')
    # require File.join(PATH, 'core',  'cutter')
    # require File.join(PATH, 'core',  'observers')
    # require File.join(PATH, 'tools', 'place_tool')
    # require File.join(PATH, 'tools', 'planview')
    # require File.join(PATH, 'ui',    'library_dialog')
    # require File.join(PATH, 'ui',    'config_dialog')

    class << self

      # ----------------------------------------------------------------- dev

      # Re-`load` every Ruby file of the extension so edits show up without
      # restarting SketchUp. `load` (unlike `require`) ignores the loaded-
      # features cache; the file_loaded? guard at the bottom of this file
      # keeps menus and toolbars from being created twice.
      #
      # @return [Integer] number of files reloaded
      def reload
        original_verbose = $VERBOSE
        $VERBOSE = nil # silence "already initialized constant" warnings
        files = Dir.glob(File.join(PATH, '**/*.rb')).sort
        files.each { |file| load file }
        puts "[ParaFrame] reloaded #{files.size} files"
        files.size
      rescue StandardError => e
        puts "[ParaFrame] reload failed: #{e.class}: #{e.message}"
        puts e.backtrace.join("\n")
        UI.messagebox("ParaFrame reload failed:\n#{e.message}")
        0
      ensure
        $VERBOSE = original_verbose
      end

      # ------------------------------------------------------- command procs
      # Placeholder actions until the real implementations land. Each tells
      # the user which phase will bring the feature, which doubles as a
      # smoke test that the command wiring works.

      def cmd_place_window
        placeholder('Place Window', 'Phase 4 (placement tool)')
      end

      def cmd_place_door
        placeholder('Place Door', 'Phase 4 (placement tool)')
      end

      def cmd_library
        placeholder('Component Library', 'Phase 8 (library dialog)')
      end

      def cmd_edit_component
        placeholder('Edit Component', 'Phase 7 (configuration dialog)')
      end

      def cmd_toggle_planview
        placeholder('Toggle Plan View', 'Phase 9 (plan view mode)')
      end

      # -------------------------------------------------------------- UI

      # Builds menu + toolbar. Called exactly once per SketchUp session via
      # the file_loaded? guard below.
      def install_ui
        commands = build_commands

        menu = UI.menu('Extensions').add_submenu('ParaFrame')
        commands.each_value { |cmd| menu.add_item(cmd) }
        menu.add_separator
        menu.add_item('Reload ParaFrame (dev)') { reload }
        menu.add_item('DC Bridge Self-Test (dev)') { DCBridge.self_test }
        menu.add_item('Dump DC Attributes of Selection (dev)') { DCBridge.dump_attributes }
        menu.add_item('DC Formula Matrix Test (dev)') { DCBridge.matrix_test }
        menu.add_item('Probe Selected DC (dev)') { DCBridge.probe_selected }

        toolbar = UI::Toolbar.new('ParaFrame')
        commands.each_value { |cmd| toolbar.add_item(cmd) }
        # restore() honours the user's previous show/hide choice; show the
        # toolbar outright on the very first run so it is discoverable.
        state = toolbar.get_last_state
        if state == TB_NEVER_SHOWN
          toolbar.show
        elsif state == TB_VISIBLE
          toolbar.restore
        end
      end

      private

      def placeholder(name, phase)
        UI.messagebox("ParaFrame — #{name}\n\nComing in #{phase}.")
      end

      # @return [Hash{Symbol => UI::Command}] insertion-ordered commands
      def build_commands
        {
          place_window: make_command(
            'Place Window', 'place_window',
            'Place a parametric window on a wall face'
          ) { cmd_place_window },
          place_door: make_command(
            'Place Door', 'place_door',
            'Place a parametric door on a wall face'
          ) { cmd_place_door },
          library: make_command(
            'Component Library', 'library',
            'Browse the ParaFrame component library'
          ) { cmd_library },
          edit: make_command(
            'Edit Component', 'edit',
            'Edit the parameters of the selected ParaFrame component'
          ) { cmd_edit_component },
          planview: make_command(
            'Toggle Plan View', 'planview',
            'Switch ParaFrame components between 2D plan symbols and 3D geometry'
          ) { cmd_toggle_planview }
        }
      end

      # @param title     [String] menu text and tooltip title
      # @param icon_base [String] icon file base name in resources/icons/
      # @param hint      [String] status bar text
      def make_command(title, icon_base, hint, &block)
        cmd = UI::Command.new(title, &block)
        small = File.join(ICONS, "#{icon_base}_24.png")
        large = File.join(ICONS, "#{icon_base}_32.png")
        cmd.small_icon = small if File.exist?(small)
        cmd.large_icon = large if File.exist?(large)
        cmd.tooltip = title
        cmd.status_bar_text = hint
        cmd
      end

    end # class << self

    unless file_loaded?(__FILE__)
      install_ui
      file_loaded(__FILE__)
    end

  end # module ParaFrame
end # module Kopji
