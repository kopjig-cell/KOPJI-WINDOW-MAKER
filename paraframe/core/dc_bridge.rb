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

      # ----------------------------------------- DC authoring (generators)
      # These encode the dictionary layout of dialog-authored components,
      # byte-verified against a SketchUp 2025 dump. Get the layout wrong
      # and the engine silently skips the component (no error, no redraw).

      # Marks a dictionary the way the Attributes dialog does. Call once
      # per definition AND once per instance that carries DC attributes.
      def init_dc_dict!(entity, name)
        entity.set_attribute(DICT_DC, '_formatversion', 1.0)
        entity.set_attribute(DICT_DC, '_lengthunits', 'INCHES')
        entity.set_attribute(DICT_DC, '_name', name)
        entity.set_attribute(DICT_DC, '_has_movetool_behaviors', 0.0)
        entity
      end

      # Declares a top-level user input on a DEFINITION: value stored as a
      # plain-number STRING (inches for lengths — the user-input
      # convention), plus its label. Example:
      #   declare_input(defn, :framewidth, 2.36, label: 'FrameWidth')
      def declare_input(definition, key, value, label: nil)
        key = normalize_key(key)
        definition.set_attribute(DICT_DC, key,
                                 value.is_a?(Numeric) ? value.to_f.to_s : value.to_s)
        definition.set_attribute(DICT_DC, "_#{key}_label", label || key)
        nil
      end

      # Declares a formula-driven attribute on a CHILD inside a DC. The
      # engine requires: the formula on the child's DEFINITION, referencing
      # the parent definition BY NAME (e.g. "CasementWindow!LenX"),
      # _hasbehaviors = 1.0 on both child instance and definition, and a
      # seed value (Float, evaluated-result convention).
      def declare_child_formula(child_instance, key, formula, seed: 0.0, label: nil)
        key = normalize_key(key)
        child_defn = definition_of(child_instance)
        [child_instance, child_defn].each do |t|
          t.set_attribute(DICT_DC, '_hasbehaviors', 1.0)
        end
        child_defn.set_attribute(DICT_DC, "_#{key}_formula", formula.to_s)
        child_defn.set_attribute(DICT_DC, "_#{key}_label", label || key)
        child_defn.set_attribute(DICT_DC, key, seed.to_f)
        child_instance.set_attribute(DICT_DC, key, seed.to_f)
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
      # Empirically established on SketchUp 2025 (see self_test):
      #  * dcs.redraw(entity, false) is the reliable entry point — the
      #    progress_bar_visible=false argument matters, a bare
      #    dcs.redraw(entity) can crash in the engine's progress counter.
      #  * redraw_with_undo returns in ~0.7 ms without doing the work in
      #    several situations, so we wrap the plain redraw in our own
      #    operation instead when an undo step is wanted.
      #  * Formulas referencing another component's LenX/Y/Z read the LIVE
      #    geometry, not the dictionary — to change a size programmatically
      #    use resize!, never a bare attribute write.
      #
      # +undo+: true wraps the redraw in its own operation (single undo
      # step). Pass undo: false when the caller already has an operation
      # open — the redraw then joins the caller's undo step.
      def redraw(instance, undo: false)
        return false unless ensure_dc!

        dcs = $dc_observers.get_latest_class
        model = instance.respond_to?(:model) && instance.model ? instance.model : Sketchup.active_model
        if undo
          model.start_operation('ParaFrame Redraw', true)
          begin
            dcs.redraw(instance, false)
            model.commit_operation
          rescue StandardError
            model.abort_operation rescue nil
            raise
          end
        else
          dcs.redraw(instance, false)
        end
        true
      rescue StandardError => e
        puts "[ParaFrame] DC redraw failed: #{e.class}: #{e.message}"
        UI.messagebox("ParaFrame: Dynamic Component redraw failed.\n#{e.message}")
        false
      end

      # Resizes a dynamic component the way the native Options dialog and
      # Scale tool do — the ONLY way that works programmatically:
      #
      #   1. scale the instance's geometry (formulas read sizes LIVE),
      #   2. record the new size in the dictionary (input-style strings),
      #   3. refresh the engine's last-size bookkeeping,
      #   4. redraw so child formulas re-evaluate against the new size.
      #
      # All four steps commit as ONE undo step. Lengths in inches; nil
      # leaves that axis unchanged.
      def resize!(instance, lenx: nil, leny: nil, lenz: nil)
        return false unless ensure_dc!

        model = instance.model
        defn = definition_of(instance)
        t = instance.transformation
        # Current size along the instance's own axes = untransformed
        # definition extents × the transformation's axis scale factors
        # (BoundingBox: width=x, depth=y, height=z).
        db = defn.bounds
        current = [db.width * t.xaxis.length,
                   db.depth * t.yaxis.length,
                   db.height * t.zaxis.length]
        targets = [lenx, leny, lenz]
        factors = targets.each_with_index.map do |target, i|
          target.nil? || current[i].zero? ? 1.0 : target.to_f / current[i]
        end

        model.start_operation('ParaFrame Resize', true)
        # Scale about the component's own origin, in its own axes.
        instance.transformation =
          t * Geom::Transformation.scaling(Geom::Point3d.new(0, 0, 0), *factors)
        %w[lenx leny lenz].each_with_index do |key, i|
          next if targets[i].nil?

          # User-input convention: plain-number string, inches.
          instance.set_attribute(DICT_DC, key, targets[i].to_f.to_s)
        end
        dcs = $dc_observers.get_latest_class
        begin
          dcs.update_last_sizes(instance)
        rescue StandardError
          nil # bookkeeping only; older builds may lack it
        end
        dcs.redraw(instance, false)
        model.commit_operation
        true
      rescue StandardError => e
        model.abort_operation rescue nil
        puts "[ParaFrame] resize! failed: #{e.class}: #{e.message}"
        UI.messagebox("ParaFrame: component resize failed.\n#{e.message}")
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
          begin
            dcs.redraw(instance, false)
            lines << "after plain redraw: width #{instance.bounds.width.round(3)}\""
          rescue StandardError => e
            lines << "plain redraw raised #{e.class}: #{e.message.to_s.lines.first.to_s.strip}"
          end
        end
        changed = (instance.bounds.width - before_w).abs > 0.001

        # Live-value cross-check: scale the geometry itself (what the
        # Scale tool / Options dialog do), then redraw — do the children
        # follow now?
        unless changed
          scale = Geom::Transformation.scaling(instance.bounds.min, 2.0, 1.0, 1.0)
          model.active_entities.transform_entities(scale, instance)
          begin
            dcs.redraw(instance, false)
            lines << "after LIVE scale x2 + redraw: width #{instance.bounds.width.round(3)}\" " \
                     '(check visually whether internals re-arranged, then Ctrl+Z)'
          rescue StandardError => e
            lines << "redraw after live scale raised #{e.class}: " \
                     "#{e.message.to_s.lines.first.to_s.strip}"
          end
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

      # Regression test of the PROVEN bridge pipeline, reachable from
      # Extensions → ParaFrame → DC Bridge Self-Test (dev).
      #
      # Builds a parent+child component through the production authoring
      # API (init_dc_dict!/declare_input/declare_child_formula), resizes it
      # with resize! — geometry-first, the way the engine actually works —
      # and verifies the child's "ParentName!LenX" formula followed.
      # Cleans up synchronously; three undo steps (build, resize, cleanup).
      def self_test(model = Sketchup.active_model)
        return false unless ensure_dc!

        checks = []
        pass = lambda do |label, ok, detail = nil|
          checks << "#{ok ? 'PASS' : 'FAIL'}  #{label}#{detail ? " (#{detail})" : ''}"
          ok
        end

        # -- build via the production authoring API --------------------------
        model.start_operation('ParaFrame Self-Test (build)', true)
        child_defn = model.definitions.add('PFSelfTestChild')
        face = child_defn.entities.add_face([0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0])
        # add_face on the ground plane usually faces down (-Z); push-pull
        # along the normal so the cube always grows upward.
        face.pushpull(face.normal.z > 0 ? 1 : -1)
        parent_defn = model.definitions.add('PFSelfTestParent')
        child = parent_defn.entities.add_instance(child_defn, Geom::Transformation.new)
        instance = model.active_entities.add_instance(parent_defn, Geom::Transformation.new)

        init_dc_dict!(parent_defn, parent_defn.name)
        init_dc_dict!(instance, parent_defn.name)
        init_dc_dict!(child_defn, child_defn.name)
        init_dc_dict!(child, child_defn.name)
        declare_input(parent_defn, :lenx, 1.0, label: 'LenX')
        declare_input(parent_defn, :sillheight, 35.0) # definition-only: fallback check
        declare_child_formula(child, :lenx, "#{parent_defn.name}!LenX",
                              seed: 1.0, label: 'LenX')
        mark_paraframe!(instance, :window)
        model.commit_operation

        # -- exercise the production resize path ------------------------------
        ok_resize = resize!(instance, lenx: 20.0)
        bounds = instance.bounds
        child_lenx = child.valid? ? get_attr(child, :lenx) : nil

        pass.call('resize! ran', ok_resize)
        pass.call('geometry resized (x=20")',
                  (bounds.width - 20.0).abs < 0.001,
                  "x=#{bounds.width.round(3)} y=#{bounds.depth.round(3)} " \
                  "z=#{bounds.height.round(3)}")
        pass.call('child formula followed (ParentName!LenX)',
                  child_lenx.to_f == 20.0, "child lenx=#{child_lenx.inspect}")
        pass.call('input read back',
                  get_attr(instance, :lenx).to_f == 20.0,
                  "lenx=#{get_attr(instance, :lenx).inspect}")
        pass.call('definition default fallback',
                  get_attr(instance, :sillheight).to_f == 35.0)
        pass.call('ParaFrame marker', paraframe_type(instance) == 'window')
        pass.call('mm round-trip',
                  (inch_to_mm(mm_to_inch(1200.0)) - 1200.0).abs < 1e-9)
        pass.call('display-unit round-trip',
                  (from_display(to_display(47.244, model), model) - 47.244).abs < 1e-9,
                  "model units: #{model_unit_name(model)}")

        # -- clean up ---------------------------------------------------------
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
        begin
          model.start_operation('ParaFrame Self-Test (crash cleanup)', true)
          instance.erase! if defined?(instance) && instance && instance.valid?
          if model.definitions.respond_to?(:remove)
            [defined?(parent_defn) ? parent_defn : nil,
             defined?(child_defn) ? child_defn : nil].compact.each do |d|
              model.definitions.remove(d) if d.valid?
            end
          end
          model.commit_operation
        rescue StandardError
          model.abort_operation rescue nil
        end
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
