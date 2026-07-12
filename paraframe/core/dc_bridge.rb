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

      # Declares a DC attribute the way the native Attributes dialog does:
      # value plus its declaration metadata. The engine enumerates a
      # component's attributes via this metadata — a bare key/value pair
      # without "_<key>_label" is invisible to the redraw (it will sync
      # size keys FROM geometry but never apply them TO geometry).
      #
      #   declare_attr(defn,  :lenx, 47.24, units: 'INCHES')
      #   declare_attr(child, :lenx, 1.0, formula: 'parent!lenx', units: 'INCHES')
      #
      # @param units [String, nil] 'INCHES' for lengths, 'DEGREES' for
      #   rotations, nil for unitless numbers/strings
      def declare_attr(entity, key, value, formula: nil, units: nil)
        key = normalize_key(key)
        entity.set_attribute(DICT_DC, key, coerce(value))
        entity.set_attribute(DICT_DC, "_#{key}_label", key)
        entity.set_attribute(DICT_DC, "_#{key}_formula", formula.to_s) if formula
        entity.set_attribute(DICT_DC, "_#{key}_units", units) if units
        nil
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

      # ------------------------------------------------ dev attribute dump

      # Prints every attribute dictionary of the selected component(s) —
      # instance AND definition, recursing into nested components — to the
      # Ruby Console. Dev tool: select any dynamic component that is known
      # to work (e.g. one authored in the native Attributes dialog) and
      # compare its dictionary layout with what ParaFrame writes.
      def dump_attributes(model = Sketchup.active_model)
        targets = model.selection.select do |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        end
        if targets.empty?
          UI.messagebox('ParaFrame: select a component or group first, ' \
                        'then run the dump again.')
          return
        end
        puts "==== ParaFrame attribute dump (#{Time.now}) ===="
        targets.each { |e| dump_entity_tree(e) }
        puts '==== end of dump ===='
        UI.messagebox("Dumped #{targets.size} component tree(s) to the " \
                      'Ruby Console (Extensions → Developer → Ruby Console).')
      end

      # Recursive worker for dump_attributes.
      def dump_entity_tree(entity, depth = 0)
        indent = '  ' * depth
        kind = entity.class.name.split('::').last
        label = entity.respond_to?(:name) && !entity.name.to_s.empty? ? " '#{entity.name}'" : ''
        defn = definition_of(entity)
        puts "#{indent}#{kind}#{label}#{defn ? " <def: #{defn.name}>" : ''}"
        dump_dicts(entity, "#{indent}  [instance] ")
        if defn
          dump_dicts(defn, "#{indent}  [definition] ")
          defn.entities.each do |child|
            next unless child.is_a?(Sketchup::ComponentInstance) ||
                        child.is_a?(Sketchup::Group)

            dump_entity_tree(child, depth + 1)
          end
        end
      end

      # Prints every dictionary/key/value pair of one entity.
      def dump_dicts(entity, prefix)
        dicts = entity.attribute_dictionaries
        return puts "#{prefix}(no attribute dictionaries)" unless dicts

        dicts.each do |dict|
          dict.each_pair do |k, v|
            puts "#{prefix}#{dict.name} | #{k} = #{v.inspect}"
          end
        end
      end

      # ------------------------------------------------- dev formula matrix

      # Dev tool that empirically discovers which dictionary layout makes
      # the DC engine evaluate child formulas in THIS SketchUp build. Each
      # variant builds a parent (input lenx=10) with a unit-cube child that
      # should end up 20" wide after the parent's lenx is overridden to 20
      # and the DC engine redraws. A variant "hits" when bounds.width==20.
      #
      # Variant axes:
      #   behaviors : also write "_hasbehaviors" = 1.0 on the definitions
      #   full_meta : add _access/_formlabel + declared x/y/z, like the
      #               native Attributes dialog writes
      #   side      : where the child's declarations live
      #               (:both / :instance / :definition)
      #   formula   : the formula string, or nil for a plain lenx=20 value
      MATRIX_VARIANTS = [
        { desc: 'baseline 0.2.3 (label+units, both sides)',
          behaviors: false, full_meta: false, side: :both, formula: 'parent!lenx' },
        { desc: 'baseline + _hasbehaviors',
          behaviors: true,  full_meta: false, side: :both, formula: 'parent!lenx' },
        { desc: 'full dialog metadata',
          behaviors: false, full_meta: true,  side: :both, formula: 'parent!lenx' },
        { desc: 'full metadata + _hasbehaviors',
          behaviors: true,  full_meta: true,  side: :both, formula: 'parent!lenx' },
        { desc: 'full+behaviors, child instance only',
          behaviors: true,  full_meta: true,  side: :instance, formula: 'parent!lenx' },
        { desc: 'full+behaviors, child definition only',
          behaviors: true,  full_meta: true,  side: :definition, formula: 'parent!lenx' },
        { desc: 'full+behaviors, leading = in formula',
          behaviors: true,  full_meta: true,  side: :both, formula: '=parent!lenx' },
        { desc: 'full+behaviors, plain value 20 (no formula)',
          behaviors: true,  full_meta: true,  side: :both, formula: nil }
      ].freeze

      def matrix_test(model = Sketchup.active_model)
        return false unless ensure_dc!

        results = MATRIX_VARIANTS.each_with_index.map do |opts, i|
          run_matrix_variant(model, i + 1, opts)
        end
        summary = "ParaFrame DC formula matrix:\n\n#{results.join("\n")}\n\n" \
                  'HIT = engine resized the child to 20". Send this list back.'
        puts "[ParaFrame] #{summary}"
        UI.messagebox(summary)
        true
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] matrix test crashed: #{e.class}: #{e.message}\n" \
             "#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame matrix test crashed:\n#{e.message}")
        false
      end

      # Builds, exercises and removes one variant; returns a result line.
      def run_matrix_variant(model, idx, opts)
        model.start_operation("PF Matrix #{idx} build", true)

        child_defn = model.definitions.add("PF Matrix #{idx} Child")
        face = child_defn.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
        face.pushpull(face.normal.z > 0 ? 1 : -1)
        parent_defn = model.definitions.add("PF Matrix #{idx}")
        child = parent_defn.entities.add_instance(child_defn, Geom::Transformation.new)
        child.name = 'MatrixChild'

        # Parent declarations (always on its definition, dialog-style).
        stamp_dict(parent_defn, 'PFMatrixParent', opts[:behaviors])
        declare_attr(parent_defn, :lenx, 10.0, units: 'INCHES')
        if opts[:full_meta]
          parent_defn.set_attribute(DICT_DC, '_lenx_access', 'TEXTBOX')
          parent_defn.set_attribute(DICT_DC, '_lenx_formlabel', 'Width')
        end

        # Child declarations on the requested side(s).
        targets = case opts[:side]
                  when :instance   then [child]
                  when :definition then [child_defn]
                  else                  [child, child_defn]
                  end
        seed = opts[:formula] ? 1.0 : 20.0
        targets.each do |t|
          stamp_dict(t, 'MatrixChild', opts[:behaviors] && t == child_defn)
          declare_attr(t, :lenx, seed, formula: opts[:formula], units: 'INCHES')
          declare_attr(t, :leny, 10.0, units: 'INCHES')
          declare_attr(t, :lenz, 10.0, units: 'INCHES')
          next unless opts[:full_meta]

          %w[x y z].each { |k| declare_attr(t, k, 0.0, units: 'INCHES') }
          %w[lenx leny lenz x y z].each do |k|
            t.set_attribute(DICT_DC, "_#{k}_access", 'TEXTBOX')
          end
        end

        instance = model.active_entities.add_instance(parent_defn,
                                                      Geom::Transformation.new)
        model.commit_operation

        set_attr(instance, :lenx, 20.0)
        redraw(instance)
        width = instance.bounds.width
        child_lenx = child.valid? ? get_attr(child, :lenx) : nil

        model.start_operation("PF Matrix #{idx} cleanup", true)
        instance.erase! if instance.valid?
        if model.definitions.respond_to?(:remove)
          model.definitions.remove(parent_defn) if parent_defn.valid?
          model.definitions.remove(child_defn) if child_defn.valid?
        end
        model.commit_operation

        hit = (width - 20.0).abs < 0.001
        "V#{idx} #{hit ? 'HIT ' : 'miss'} w=#{width.round(3)} " \
          "childlenx=#{child_lenx.inspect} — #{opts[:desc]}"
      end

      # Common per-dictionary stamps the Attributes dialog writes.
      def stamp_dict(entity, name, behaviors)
        entity.set_attribute(DICT_DC, '_formatversion', 1.0)
        entity.set_attribute(DICT_DC, '_lengthunits', 'INCHES')
        entity.set_attribute(DICT_DC, '_name', name)
        entity.set_attribute(DICT_DC, '_hasbehaviors', 1.0) if behaviors
      end

      # ------------------------------------------------- dev probe selected

      # Runs ParaFrame's write-and-redraw sequence against a KNOWN-GOOD,
      # dialog-authored dynamic component selected by the user: doubles its
      # lenx via the engine's set_attribute, redraws, and measures whether
      # the geometry followed. If this HITs, our call sequence is sound and
      # only our component-creation side differs from the dialog's output.
      # Undo (Ctrl+Z) restores the component afterwards.
      def probe_selected(model = Sketchup.active_model)
        return false unless ensure_dc!

        instance = model.selection.grep(Sketchup::ComponentInstance).first
        unless instance
          UI.messagebox('ParaFrame probe: select a dynamic component ' \
                        'instance first (one that resizes via Component ' \
                        'Options), then run again.')
          return false
        end

        dcs = $dc_observers.get_latest_class
        raw = instance.get_attribute(DICT_DC, 'lenx') ||
              definition_of(instance)&.get_attribute(DICT_DC, 'lenx')
        if raw.nil?
          UI.messagebox('ParaFrame probe: the selected component has no ' \
                        "lenx dynamic attribute — pick one with LenX in " \
                        'Component Attributes.')
          return false
        end

        before_w = instance.bounds.width
        target = raw.to_f * 2 # stored units (whatever the dict declares)
        lines = ["stored lenx=#{raw.inspect} → writing #{target}"]

        begin
          dcs.set_attribute(instance, 'lenx', target.to_s)
          lines << 'write via dcs.set_attribute: ok'
        rescue StandardError => e
          instance.set_attribute(DICT_DC, 'lenx', target.to_s)
          lines << "dcs.set_attribute raised #{e.class} — wrote dict directly"
        end

        redraw(instance) # redraw_with_undo path
        mid_w = instance.bounds.width
        lines << "after redraw_with_undo: width #{before_w.round(3)}\" → #{mid_w.round(3)}\""
        if (mid_w - before_w).abs < 0.001 && dcs.respond_to?(:redraw)
          dcs.redraw(instance)
          lines << "after plain redraw: width #{instance.bounds.width.round(3)}\""
        end
        changed = (instance.bounds.width - before_w).abs > 0.001

        # Live-value cross-check: scale the geometry itself (what the
        # Scale tool / Options dialog do), then redraw — do the children
        # follow now?
        unless changed
          scale = Geom::Transformation.scaling(instance.bounds.min, 2.0, 1.0, 1.0)
          model.active_entities.transform_entities(scale, instance)
          dcs.redraw(instance)
          lines << "after LIVE scale x2 + redraw: width #{instance.bounds.width.round(3)}\" " \
                   '(check visually whether internals re-arranged, then Ctrl+Z)'
        end
        verdict = changed ? 'CHANGED — our call sequence works on real DCs.' :
                            'unchanged — even a dialog-authored DC ignores our sequence.'
        msg = "ParaFrame probe on '#{definition_of(instance)&.name}':\n\n" \
              "#{lines.join("\n")}\n\n#{verdict}\n\n(Ctrl+Z to restore the component.)"
        puts "[ParaFrame] #{msg}"
        UI.messagebox(msg)
        changed
      rescue StandardError => e
        puts "[ParaFrame] probe crashed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        UI.messagebox("ParaFrame probe crashed:\n#{e.message}")
        false
      end

      # ---------------------------------------------------- dev self-test

      # End-to-end probe of the DC engine, reachable from Extensions →
      # ParaFrame → DC Bridge Self-Test (dev). Two authoring strategies are
      # tried on a parent+child component (child width must follow the
      # parent's lenx input to 20"):
      #
      #   Phase A — replicate the dictionary layout of a dialog-authored DC
      #     exactly as dumped from a live SketchUp 2026: attribute VALUES
      #     stored as STRINGS (in the units declared by _lengthunits, here
      #     INCHES), dialog stamps (_formatversion/_lengthunits/_name/
      #     _has_movetool_behaviors/_lastmodified) on definition AND
      #     instance dictionaries.
      #
      #   Phase B — if A misses: write through the engine's OWN authoring
      #     API (set_attribute / set_attribute_formula), probing their
      #     parameter lists (printed to the console) for the right arity.
      #
      # A deferred re-measure runs 2 s later, then cleanup. Everything is
      # reported via messagebox AND the Ruby Console.
      def self_test(model = Sketchup.active_model)
        return false unless ensure_dc!

        dcs = $dc_observers.get_latest_class
        log = []
        say = lambda do |line|
          log << line
          puts "[ParaFrame] #{line}"
        end

        say.call("DC engine: #{dcs.class}")
        # Parameter lists of the engine's authoring API (console only).
        %i[set_attribute set_attribute_formula get_attribute_value redraw
           redraw_with_undo run_all_formulas store_nominal_size
           update_last_sizes has_behaviors children_have_behaviors].each do |m|
          next unless dcs.respond_to?(m)

          puts "[ParaFrame]   dcs.#{m} params: #{dcs.method(m).parameters.inspect}"
        end

        # -- build ----------------------------------------------------------
        # Byte-level replication of a dialog-authored DC as dumped from
        # SketchUp 2025: user inputs are STRINGS of inch-numbers, evaluated
        # results are Floats, the child formula lives on the child
        # DEFINITION only and references the parent BY NAME, the child
        # carries _hasbehaviors=1.0 on instance AND definition, the parent
        # definition carries _len*_nominal bookkeeping.
        model.start_operation('ParaFrame Self-Test (build)', true)
        child_defn = model.definitions.add('PFSelfTestChild')
        face = child_defn.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
        # add_face on the ground plane usually faces down (-Z); push-pull
        # along the normal so the cube always grows upward.
        face.pushpull(face.normal.z > 0 ? 1 : -1)
        parent_defn = model.definitions.add('PFSelfTestParent')
        child = parent_defn.entities.add_instance(child_defn, Geom::Transformation.new)
        instance = model.active_entities.add_instance(parent_defn, Geom::Transformation.new)
        mark_paraframe!(instance, :window)

        stamp = lambda do |entity, name|
          entity.set_attribute(DICT_DC, '_lengthunits', 'INCHES')
          entity.set_attribute(DICT_DC, '_name', name)
          entity.set_attribute(DICT_DC, '_has_movetool_behaviors', 0.0)
        end

        # Parent definition — input lenx as STRING + nominal bookkeeping.
        stamp.call(parent_defn, parent_defn.name)
        parent_defn.set_attribute(DICT_DC, '_formatversion', 1.0)
        parent_defn.set_attribute(DICT_DC, '_lastmodified',
                                  Time.now.strftime('%Y-%m-%d %H:%M'))
        parent_defn.set_attribute(DICT_DC, '_lenx_label', 'LenX')
        parent_defn.set_attribute(DICT_DC, 'lenx', '20.0')
        parent_defn.set_attribute(DICT_DC, '_lenx_nominal', 1.0)
        parent_defn.set_attribute(DICT_DC, '_leny_nominal', 1.0)
        parent_defn.set_attribute(DICT_DC, '_lenz_nominal', 1.0)
        # sillheight only on the definition — proves instance→definition
        # fallback further down.
        parent_defn.set_attribute(DICT_DC, 'sillheight', 35.0)

        # Parent instance — mirrors the input (dump shows NO _hasbehaviors
        # on the parent).
        stamp.call(instance, parent_defn.name)
        instance.set_attribute(DICT_DC, 'lenx', '20.0')

        # Child definition — formula by parent NAME, dialog-case reference.
        formula = "#{parent_defn.name}!LenX"
        stamp.call(child_defn, child_defn.name)
        child_defn.set_attribute(DICT_DC, '_formatversion', 1.0)
        child_defn.set_attribute(DICT_DC, '_hasbehaviors', 1.0)
        child_defn.set_attribute(DICT_DC, '_lastmodified',
                                 Time.now.strftime('%Y-%m-%d %H:%M'))
        child_defn.set_attribute(DICT_DC, '_lenx_label', 'LenX')
        child_defn.set_attribute(DICT_DC, '_lenx_formula', formula)
        child_defn.set_attribute(DICT_DC, 'lenx', 1.0)
        child_defn.set_attribute(DICT_DC, '_leny_label', 'LenY')
        child_defn.set_attribute(DICT_DC, 'leny', '10.0')
        child_defn.set_attribute(DICT_DC, '_lenz_label', 'LenZ')
        child_defn.set_attribute(DICT_DC, 'lenz', '10.0')

        # Child instance — evaluated-style Float value + _hasbehaviors.
        stamp.call(child, child_defn.name)
        child.set_attribute(DICT_DC, '_hasbehaviors', 1.0)
        child.set_attribute(DICT_DC, '_iscollapsed', 'false')
        child.set_attribute(DICT_DC, 'lenx', 1.0)
        model.commit_operation

        say.call("child formula = #{formula.inspect}")
        begin
          dcs.update_last_sizes(instance)
          say.call('dcs.update_last_sizes(instance): ok')
        rescue StandardError => e
          say.call("dcs.update_last_sizes raised #{e.class}: #{e.message}")
        end

        # Helper: report x/y/z extents (BoundingBox: width=x, depth=y,
        # height=z) plus the child's stored lenx.
        measure = lambda do |tag|
          b = instance.bounds
          say.call("#{tag}: x=#{b.width.round(3)} y=#{b.depth.round(3)} " \
                   "z=#{b.height.round(3)} child lenx=" \
                   "#{child.valid? ? get_attr(child, :lenx).inspect : 'n/a'}")
          b.width
        end

        # -- Phase A: attribute write + redraw (the classic recipe) ---------
        dcs.redraw(instance)
        hit_a = (measure.call('Phase A attr+redraw') - 20.0).abs < 0.001

        # -- Phase B: bare formula-evaluation pass ---------------------------
        hit_b = false
        unless hit_a
          begin
            dcs.run_all_formulas(instance)
            hit_b = (measure.call('Phase B run_all_formulas') - 20.0).abs < 0.001
          rescue StandardError => e
            say.call("Phase B crashed: #{e.class}: #{e.message}")
          end
        end

        # -- Phase C: LIVE-VALUE theory decider ------------------------------
        # Hypothesis: formulas read len* of other components from LIVE
        # geometry, not from the dictionary — the Options dialog physically
        # scales the component first, then redraws. So: scale the root to
        # 20" wide by transform (what the dialog/Scale tool does), redraw,
        # and see whether the child now follows the formula, and whether
        # its dictionary leny/lenz (10") get applied to geometry.
        unless hit_a || hit_b
          begin
            model.start_operation('ParaFrame Self-Test (scale)', true)
            scale = Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0),
                                                 20.0, 1.0, 1.0)
            model.active_entities.transform_entities(scale, instance)
            model.commit_operation
            measure.call('Phase C after live scale x20 (before redraw)')
            dcs.redraw(instance)
            measure.call('Phase C after redraw')
            begin
              dcs.update_last_sizes(instance)
              dcs.redraw(instance)
              measure.call('Phase C after update_last_sizes + redraw')
            rescue StandardError => e
              say.call("update_last_sizes step: #{e.class}: #{e.message}")
            end
          rescue StandardError => e
            say.call("Phase C crashed: #{e.class}: #{e.message}")
          end
        end

        # Bridge regression checks (independent of the engine).
        say.call("fallback=#{get_attr(instance, :sillheight, :none).inspect} " \
                 "marker=#{paraframe_type(instance).inspect} " \
                 "mm_ok=#{(inch_to_mm(mm_to_inch(1200.0)) - 1200.0).abs < 1e-9} " \
                 "display_ok=#{(from_display(to_display(47.244, model), model) - 47.244).abs < 1e-9} " \
                 "(model units: #{model_unit_name(model)})")

        UI.messagebox("ParaFrame self-test (immediate):\n\n#{log.join("\n")}\n\n" \
                      'Second messagebox follows in ~2 s.')

        # -- deferred re-measure + cleanup ------------------------------------
        UI.start_timer(2.0, false) do
          begin
            late_width = instance.valid? ? instance.bounds.width : -1.0
            late_child = child.valid? ? get_attr(child, :lenx) : nil
            late_msg = "ParaFrame deferred re-measure (2 s later):\n" \
                       "bounds.width=#{late_width.round(3)}\", " \
                       "child lenx=#{late_child.inspect}\n" +
                       ((late_width - 20.0).abs < 0.001 ?
                         'RESIZED late — engine applies asynchronously.' :
                         'Still unresized.')
            puts "[ParaFrame] #{late_msg}"
            model.start_operation('ParaFrame Self-Test (cleanup)', true)
            instance.erase! if instance.valid?
            if model.definitions.respond_to?(:remove)
              model.definitions.remove(parent_defn) if parent_defn.valid?
              model.definitions.remove(child_defn) if child_defn.valid?
            end
            model.commit_operation
            UI.messagebox(late_msg)
          rescue StandardError => e
            puts "[ParaFrame] deferred check failed: #{e.class}: #{e.message}"
          end
        end
        true
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
