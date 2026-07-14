# frozen_string_literal: true

# Persistent user settings, stored via Sketchup.read_default /
# write_default under the "ParaFrame" section so they survive across
# sessions and models.

require 'sketchup.rb'

module Kopji
  module ParaFrame
    module Settings

      SECTION = 'ParaFrame'

      # key => default (millimetres or plain values)
      DEFAULTS = {
        'cut_depth_mm' => 600, # how far the cutter reaches through a wall
        'reveal_mm'    => 0    # inset of the opening from the frame outline
      }.freeze

      module_function

      def get(key)
        Sketchup.read_default(SECTION, key, DEFAULTS[key])
      end

      def set(key, value)
        Sketchup.write_default(SECTION, key, value)
      end

      # Maximum cut depth as an internal length (inches).
      def cut_depth
        get('cut_depth_mm').to_f.mm
      end

      # Opening reveal inset as an internal length (inches).
      def reveal
        get('reveal_mm').to_f.mm
      end

    end # module Settings
  end # module ParaFrame
end # module Kopji
