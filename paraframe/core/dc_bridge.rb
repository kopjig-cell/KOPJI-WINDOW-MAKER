# frozen_string_literal: true

# DCBridge — the only place in ParaFrame that talks to the Dynamic
# Components (DC) attribute system directly.
#
# How DC stores its data (background for maintenance):
#
# * Every dynamic component carries an AttributeDictionary named
#   "dynamic_attributes".
#   - On the ComponentDefinition it holds the *defaults* and all metadata:
#     for an attribute "lenx" the value lives under key "lenx" and its
#     metadata under underscore-prefixed keys such as "_lenx_formula",
#     "_lenx_label", "_lenx_units", "_lenx_access".
#   - On the ComponentInstance it holds the *current* (user-overridden)
#     values only, e.g. "lenx" => 24.0. Reading must therefore check the
#     instance first and fall back to the definition.
# * Keys are always lowercase. "lenx"/"leny"/"lenz" are the component size
#   along its internal axes.
# * All lengths are stored in INCHES (SketchUp's native unit), regardless
#   of what units the model displays. Unit conversion is display-only and
#   handled by the helpers at the bottom of this file.
# * Geometry only updates after the DC engine re-evaluates the component:
#   $dc_observers.get_latest_class.redraw_with_undo(instance). If the
#   Dynamic Components extension is disabled, $dc_observers is nil — every
#   entry point here guards for that.
#
# ParaFrame additionally tags its own components with a separate dictionary
# named "ParaFrame" (marker key "paraframe_type" = "window" | "door"), so we
# never mistake a third-party DC for one of ours.

require 'sketchup.rb'

module Kopji
  module ParaFrame
    module DCBridge

      # Dictionary the DC engine reads.
      DICT_DC = 'dynamic_attributes'
      # ParaFrame's own dictionary (marker + cut records later).
      DICT_PF = 'ParaFrame'
      # Marker key inside DICT_PF.
      KEY_TYPE = 'paraframe_type'

      # Millimetres per inch — the one conversion constant everything else
      # derives from.
      MM_PER_INCH = 25.4

      # model.options["UnitsOptions"]["LengthUnit"] codes → inches per one
      # displayed unit. (0=in, 1=ft, 2=mm, 3=cm, 4=m, 5=yd)
      INCHES_PER_UNIT = {
        0 => 1.0,
        1 => 12.0,
        2 => 1.0 / 25.4,
        3 => 1.0 / 2.54,
        4 => 100.0 / 2.54,
        5 => 36.0
      }.freeze

      UNIT_NAMES = { 0 => 'in', 1 => 'ft', 2 => 'mm', 3 => 'cm',
                     4 => 'm', 5 => 'yd' }.freeze

      module_function

      # ---------------------------------------------------- DC availability

      # True when the Dynamic Components extension is loaded and enabled.
      def dc_available?
        !!(defined?($dc_observers) && $dc_observers)
      end

      # Guard for user-triggered paths: returns true when DC is usable,
      # otherwise warns once per call and returns false so the caller can
      # bail out cleanly instead of crashing.
      def ensure_dc!
        return true if dc_available?

        UI.messagebox(
          "ParaFrame needs the Dynamic Components extension.\n\n" \
          'Enable it under Extensions → Extension Manager ' \
          '("Dynamic Components" ships with SketchUp), then try again.'
        )
        false
      end

      # ------------------------------------------------- attribute get/set

      # Reads a dynamic attribute the way the DC engine resolves it:
      # instance override first, then the definition default.
      #
      # @param instance [Sketchup::ComponentInstance, Sketchup::Group]
      # @param key      [String, Symbol] attribute name, e.g. :lenx
      # @param default  [Object] returned when neither holds the key
      def get_attr(instance, key, default = nil)
        key = normalize_key(key)
        value = instance.get_attribute(DICT_DC, key)
        value = definition_of(instance)&.get_attribute(DICT_DC, key) if value.nil?
        value.nil? ? default : value
      end

      # Writes a *current value* onto the instance — exactly what the native
      # Component Options dialog does when the user edits a field. The
      # definition's defaults and formulas stay untouched; the next redraw
      # re-evaluates formulas against this new input.
      #
      # Numeric values are stored as Float because the DC engine expects
      # doubles (an Integer 3 and Float 3.0 are not interchangeable in DC
      # formula results).
      def set_attr(instance, key, value)
        instance.set_attribute(DICT_DC, normalize_key(key), coerce(value))
      end

      # Writes a *default* onto the definition — used by the component
      # generators (Phase 3) and by "save as preset" (Phase 8). Accepts an
      # instance for convenience.
      def set_definition_attr(entity, key, value)
        target = entity.respond_to?(:definition) ? entity.definition : entity
        target.set_attribute(DICT_DC, normalize_key(key), coerce(value))
      end

      # Writes a DC formula for +key+ onto +entity+ EXACTLY where given —
      # no definition redirect — because the DC engine reads from different
      # places at different levels (this is how the native Attributes
      # dialog stores them):
      #
      #   * top-level component → pass the ComponentDefinition
      #   * sub-component inside a DC → pass the child ComponentInstance;
      #     formulas on a child's *definition* are IGNORED by the engine.
      #
      # Per DC convention the formula lives under "_<key>_formula" and the
      # key itself keeps the last evaluated value (we seed it with +seed+ so
      # the dictionary is complete before the first redraw).
      def set_formula(entity, key, formula, seed = 0.0)
        key = normalize_key(key)
        entity.set_attribute(DICT_DC, "_#{key}_formula", formula.to_s)
        entity.set_attribute(DICT_DC, key, coerce(seed))
      end

      # Removes an instance's override so the definition default/formula
      # applies again on the next redraw.
      def clear_attr(instance, key)
        dict = instance.attribute_dictionary(DICT_DC, false)
        dict&.delete_key(normalize_key(key))
      end

      # All resolved dynamic attributes of an instance as a Hash — the
      # definition defaults merged with the instance overrides. Metadata
      # keys (leading underscore) are skipped; this is the data the config
      # dialog (Phase 7) will render.
      def attrs_hash(instance)
        result = {}
        defn_dict = definition_of(instance)&.attribute_dictionary(DICT_DC, false)
        inst_dict = instance.attribute_dictionary(DICT_DC, false)
        [defn_dict, inst_dict].compact.each do |dict|
          dict.each_pair do |k, v|
            result[k] = v unless k.start_with?('_')
          end
        end
        result
      end

      # ------------------------------------------------------------ redraw

      # Asks the DC engine to re-evaluate formulas and rebuild the
      # instance's geometry. Returns true on success.
      #
      # +undo+: redraw_with_undo wraps the redraw in its own undo step —
      # right when the redraw IS the user action. Pass undo: false when the
      # caller is already inside model.start_operation (the DC engine then
      # redraws within the caller's open operation, keeping one undo step).
      def redraw(instance, undo: true)
        return false unless ensure_dc!

        dcs = $dc_observers.get_latest_class
        if undo && dcs.respond_to?(:redraw_with_undo)
          dcs.redraw_with_undo(instance)
        else
          dcs.redraw(instance)
        end
        true
      rescue StandardError => e
        puts "[ParaFrame] DC redraw failed: #{e.class}: #{e.message}"
        UI.messagebox("ParaFrame: Dynamic Component redraw failed.\n#{e.message}")
        false
      end

      # ---------------------------------------------------- ParaFrame marker

      # Tags an instance as a ParaFrame component. +type+ is "window" or
      # "door". Also mirrored onto the definition so library components keep
      # their identity when saved out to .skp.
      def mark_paraframe!(instance, type)
        instance.set_attribute(DICT_PF, KEY_TYPE, type.to_s)
        definition_of(instance)&.set_attribute(DICT_PF, KEY_TYPE, type.to_s)
        instance
      end

      # "window", "door" … or nil when the entity is not ours.
      def paraframe_type(entity)
        return nil unless entity.respond_to?(:get_attribute)

        entity.get_attribute(DICT_PF, KEY_TYPE) ||
          (entity.respond_to?(:definition) &&
            entity.definition.get_attribute(DICT_PF, KEY_TYPE)) ||
          nil
      end

      # True for instances placed/tagged by ParaFrame.
      def paraframe_component?(entity)
        !paraframe_type(entity).nil?
      end

      # -------------------------------------------------------------- units

      # LengthUnit code of the model's display units (see INCHES_PER_UNIT).
      def model_unit_code(model = Sketchup.active_model)
        model.options['UnitsOptions']['LengthUnit']
      end

      # Short display-unit suffix for UI labels, e.g. "mm".
      def model_unit_name(model = Sketchup.active_model)
        UNIT_NAMES.fetch(model_unit_code(model), 'in')
      end

      # Internal inches → number in the model's display units (for showing
      # in dialog fields; formatting/rounding is the dialog's job).
      def to_display(inches, model = Sketchup.active_model)
        inches / INCHES_PER_UNIT.fetch(model_unit_code(model), 1.0)
      end

      # Number typed by the user in the model's display units → inches.
      def from_display(value, model = Sketchup.active_model)
        value.to_f * INCHES_PER_UNIT.fetch(model_unit_code(model), 1.0)
      end

      # Millimetre helpers — ParaFrame's own defaults are specified metric.
      def mm_to_inch(mm)
        mm.to_f / MM_PER_INCH
      end

      def inch_to_mm(inches)
        inches.to_f * MM_PER_INCH
      end

      # Human-readable length in the model's current display format,
      # e.g. 47.244" shown as "1200 mm" in a metric model.
      def format_length(inches)
        Sketchup.format_length(inches)
      end

      # ---------------------------------------------------- dev self-test

      # End-to-end check of the bridge inside a live SketchUp session,
      # reachable from Extensions → ParaFrame → DC Bridge Self-Test (dev).
      #
      # The DC engine's redraw applies size/position attributes to the
      # CHILDREN of a dynamic component (evaluating formulas such as
      # "parent!lenx"); it does not rescale a childless root. So the test
      # mirrors how real DCs — and our Phase 3 components — are built:
      # a parent whose "lenx" is a plain input, containing a child cube
      # whose own lenx is the formula "parent!lenx". Overriding the
      # parent's lenx to 20" and redrawing must stretch the child to 20".
      # Cleans up after itself (three undo steps: build, DC redraw,
      # cleanup).
      def self_test(model = Sketchup.active_model)
        return false unless ensure_dc!

        checks = []
        pass = lambda do |label, ok, detail = nil|
          checks << "#{ok ? 'PASS' : 'FAIL'}  #{label}#{detail ? " (#{detail})" : ''}"
          ok
        end

        # -- build: parent DC with one formula-driven child ----------------
        model.start_operation('ParaFrame Self-Test (build)', true)

        # Child geometry: a 1" unit cube; the DC engine scales it to
        # whatever lenx/leny/lenz evaluate to on redraw.
        child_defn = model.definitions.add('ParaFrame Self-Test Child')
        face = child_defn.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
        # add_face on the ground plane usually faces down (-Z); push-pull
        # along the normal direction so the cube always grows upward.
        face.pushpull(face.normal.z > 0 ? 1 : -1)

        parent_defn = model.definitions.add('ParaFrame Self-Test')
        child = parent_defn.entities.add_instance(child_defn, Geom::Transformation.new)

        # Parent inputs live on its definition as defaults; sillheight
        # exists ONLY there so we can prove the instance→definition
        # fallback. _formatversion marks the dict the way the native
        # Attributes dialog does.
        parent_defn.set_attribute(DICT_DC, '_formatversion', 1.0)
        set_definition_attr(parent_defn, :lenx, 10.0)
        set_definition_attr(parent_defn, :sillheight, 35.0)

        # Child: width follows the parent input, depth/height fixed 10".
        # Everything goes on the child INSTANCE dictionary — the engine
        # ignores formulas on a sub-component's definition.
        child.set_attribute(DICT_DC, '_formatversion', 1.0)
        set_formula(child, :lenx, 'parent!lenx', 10.0)
        set_attr(child, :leny, 10.0)
        set_attr(child, :lenz, 10.0)

        instance = model.active_entities.add_instance(parent_defn, Geom::Transformation.new)
        mark_paraframe!(instance, :window)
        model.commit_operation

        # -- exercise the bridge -------------------------------------------
        set_attr(instance, :LenX, 20.0) # mixed case on purpose → "lenx"
        ok_redraw = redraw(instance)    # own undo step (user-level action)

        pass.call('DC redraw ran', ok_redraw)
        pass.call('instance override read back',
                  get_attr(instance, :lenx) == 20.0,
                  "lenx=#{get_attr(instance, :lenx).inspect}")
        # Rich detail: bounds W×H×D plus the child's evaluated lenx, so a
        # failure shows whether formulas evaluated and which size
        # attributes were applied (width=x, height=y, depth=z).
        bounds = instance.bounds
        width = bounds.width
        child_lenx = child.valid? ? get_attr(child, :lenx) : nil
        pass.call('formula-driven child resized (child lenx = parent!lenx)',
                  (width - 20.0).abs < 0.001,
                  "bounds=#{bounds.width.round(3)}x#{bounds.height.round(3)}x" \
                  "#{bounds.depth.round(3)}\", child lenx=#{child_lenx.inspect}")
        pass.call('definition default fallback',
                  get_attr(instance, :sillheight) == 35.0)
        pass.call('ParaFrame marker', paraframe_type(instance) == 'window')
        pass.call('attrs_hash merges',
                  attrs_hash(instance)['lenx'] == 20.0 &&
                  attrs_hash(instance)['sillheight'] == 35.0)
        pass.call('mm round-trip', (inch_to_mm(mm_to_inch(1200.0)) - 1200.0).abs < 1e-9)
        pass.call('display-unit round-trip',
                  (from_display(to_display(47.244, model), model) - 47.244).abs < 1e-9,
                  "model units: #{model_unit_name(model)}")

        # -- clean up -------------------------------------------------------
        model.start_operation('ParaFrame Self-Test (cleanup)', true)
        instance.erase! if instance.valid?
        if model.definitions.respond_to?(:remove)
          model.definitions.remove(parent_defn) if parent_defn.valid?
          model.definitions.remove(child_defn) if child_defn.valid?
        end
        model.commit_operation

        all_ok = checks.none? { |line| line.start_with?('FAIL') }
        summary = "ParaFrame DC bridge self-test: #{all_ok ? 'ALL PASS' : 'FAILURES'}\n\n" +
                  checks.join("\n")
        puts "[ParaFrame] #{summary}"
        UI.messagebox(summary)
        all_ok
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] self-test crashed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame self-test crashed:\n#{e.message}")
        false
      end

      # ------------------------------------------------------------ helpers

      # Definition of an instance or group (Group#definition exists on all
      # supported SketchUp versions); nil for anything else.
      def definition_of(entity)
        entity.respond_to?(:definition) ? entity.definition : nil
      end

      # DC keys must be lowercase Strings.
      def normalize_key(key)
        key.to_s.downcase
      end

      # DC stores numbers as doubles; leave strings/booleans as-is.
      def coerce(value)
        value.is_a?(Numeric) ? value.to_f : value
      end

    end # module DCBridge
  end # module ParaFrame
end # module Kopji
