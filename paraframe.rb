# frozen_string_literal: true

# ParaFrame — parametric doors & windows for SketchUp.
#
# This is the registration loader. It must stay tiny: SketchUp evaluates every
# .rb file in the Plugins folder at startup, so all real code lives under
# paraframe/ and is only loaded when the extension is enabled.
#
# Copyright (c) 2026 Kopji. All rights reserved.
# Original work — not affiliated with, nor derived from, any other extension.

require 'sketchup.rb'
require 'extensions.rb'

module Kopji
  module ParaFrame

    # Single source of truth for the version. build/package.rb reads and
    # bumps this string, so keep the `VERSION = '…'` line machine-parseable.
    VERSION = '0.7.1'

    # SketchUp 2021 ships Ruby 2.7 and reports version "21.x".
    MINIMUM_SKETCHUP_VERSION = 21

    unless file_loaded?(__FILE__)
      if Sketchup.version.to_i < MINIMUM_SKETCHUP_VERSION
        UI.messagebox(
          "ParaFrame requires SketchUp 2021 or newer.\n" \
          "This SketchUp reports version #{Sketchup.version}."
        )
      else
        extension = SketchupExtension.new('ParaFrame', 'paraframe/main')
        extension.description = 'Parametric doors and windows with automatic ' \
                                'multi-layer wall cutting, powered by Dynamic ' \
                                'Components.'
        extension.version   = VERSION
        extension.creator   = 'Kopji'
        extension.copyright = "© 2026 Kopji"
        Sketchup.register_extension(extension, true)
      end
      file_loaded(__FILE__)
    end

  end # module ParaFrame
end # module Kopji
