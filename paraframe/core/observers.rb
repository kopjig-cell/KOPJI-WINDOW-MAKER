# frozen_string_literal: true

# Observers — keeps wall openings in sync with their components, live:
#
#   * move a placed window/door           → debounce → recut
#   * scale it (native Scale tool)        → debounce → DC redraw + recut
#   * erase it                            → debounce → heal from a cached
#                                           copy of its cut record (the
#                                           dictionary dies with the
#                                           instance)
#   * undo / redo                         → suppress reactions and refresh
#                                           caches (the model already
#                                           carries the restored state; a
#                                           recut here would pollute the
#                                           undo stack)
#
# Wiring: an AppObserver attaches a ModelObserver + EntitiesObserver to
# every model (new/open/startup); every ParaFrame instance additionally
# gets an EntityObserver for transform changes. All reactions funnel into
# one debounced timer per model (UI.start_timer, 0.2 s) so drag-storms of
# onChangeEntity events collapse into a single recut.
#
# All mutable state lives in STATE, which survives the dev "reload"
# (constants are kept across `load`), so observers are never attached
# twice.

require 'sketchup.rb'
require 'json'

module Kopji
  module ParaFrame
    module Observers

      DEBOUNCE = 0.2 # seconds
      # How long after an undo/redo reactions stay suppressed (seconds).
      UNDO_QUIET = 0.5

      # Survives dev reloads; all keys namespaced by model.guid.
      STATE = {
        installed: false,
        singletons: {}, # observer instances, created once
        attached: {},   # model.guid => true
        watched: {},    # model.guid => { entityID => state hash }
        dirty: {},      # model.guid => { entityID => true }
        heal_queue: {}, # model.guid => [record JSON, ...]
        timer: {},      # model.guid => true while a debounce timer runs
        quiet_until: {} # model.guid => Time
      } unless defined?(STATE)

      # ------------------------------------------------- observer classes

      class PFEntityObserver < Sketchup::EntityObserver
        def onChangeEntity(entity)
          Observers.entity_changed(entity)
        end

        # Fires for the exact instance we observe — a reliable erase signal
        # even when the model-level onElementRemoved reports an id we are
        # not keyed on.
        def onEraseEntity(entity)
          Observers.entity_erased(entity)
        rescue StandardError => e
          puts "[ParaFrame] onEraseEntity: #{e.class}: #{e.message}"
        end
      end

      class PFEntitiesObserver < Sketchup::EntitiesObserver
        def onElementRemoved(entities, entity_id)
          Observers.element_removed(entities.model, entity_id)
        rescue StandardError => e
          puts "[ParaFrame] onElementRemoved: #{e.class}: #{e.message}"
        end
      end

      class PFModelObserver < Sketchup::ModelObserver
        def onTransactionUndo(model)
          Observers.transaction_jump(model)
        end

        def onTransactionRedo(model)
          Observers.transaction_jump(model)
        end
      end

      class PFAppObserver < Sketchup::AppObserver
        def onNewModel(model)
          Observers.attach(model)
        end

        def onOpenModel(model)
          Observers.attach(model)
        end

        def expectsStartupModelNotifications
          true
        end
      end

      class << self

        # ------------------------------------------------------- lifecycle

        # Installs the AppObserver once per SketchUp session and attaches
        # to the current model. Safe to call repeatedly (dev reload).
        def install
          unless STATE[:installed]
            Sketchup.add_observer(singleton(:app) { PFAppObserver.new })
            STATE[:installed] = true
          end
          attach(Sketchup.active_model) if Sketchup.active_model
        end

        # Attaches model-level observers once per model and registers any
        # ParaFrame instances already present (e.g. reopened files).
        def attach(model)
          return unless model
          key = model.guid
          return if STATE[:attached][key]

          model.entities.add_observer(singleton(:entities) { PFEntitiesObserver.new })
          model.add_observer(singleton(:model) { PFModelObserver.new })
          STATE[:attached][key] = true
          rescan(model)
        end

        # (Re)registers every ParaFrame instance at the model root.
        def rescan(model)
          model.entities.grep(Sketchup::ComponentInstance).each do |inst|
            watch(inst) if DCBridge.paraframe_component?(inst)
          end
        end

        # Registers one instance: caches its cut record + transform and
        # attaches an EntityObserver (only on first registration, so
        # repeated watch() calls — e.g. after every recut — do not stack
        # duplicate observers).
        def watch(instance)
          model = instance.model
          return unless model

          attach(model)
          map = (STATE[:watched][model.guid] ||= {})
          st = map[instance.entityID]
          unless st
            st = {}
            map[instance.entityID] = st
            instance.add_observer(singleton(:entity) { PFEntityObserver.new })
          end
          st[:instance] = instance
          st[:model]    = model
          st[:matrix]   = instance.transformation.to_a
          st[:record]   = Cutter.raw_record(instance)
          n = begin
            JSON.parse(st[:record] || '[]').length
          rescue JSON::ParserError
            0
          end
          puts "[ParaFrame] watch ##{instance.entityID} " \
               "(#{DCBridge.paraframe_type(instance)}): #{n} cut layer(s) cached"
          nil
        end

        # ------------------------------------------------- event funnels

        def entity_changed(entity)
          model = entity.respond_to?(:model) ? entity.model : nil
          return unless model

          key = model.guid
          return unless STATE[:watched].dig(key, entity.entityID)

          (STATE[:dirty][key] ||= {})[entity.entityID] = true
          schedule(model)
        end

        def element_removed(model, entity_id)
          return unless model

          key = model.guid
          st = STATE[:watched].dig(key, entity_id)
          unless st
            # Not one we watch by this id — but it may still be a stale id
            # from a swapped instance. Reconcile below in reconcile_watched.
            reconcile_watched(model)
            return
          end

          puts "[ParaFrame] onElementRemoved matched ##{entity_id}"
          queue_heal(model, entity_id, st, 'onElementRemoved')
        end

        # Backstop: the EntityObserver fires for the exact instance we
        # watch, so this catches erases even if the model-level id lookup
        # missed.
        def entity_erased(entity)
          id = begin
            entity.entityID
          rescue StandardError
            nil
          end
          STATE[:watched].each do |key, map|
            model = map.values.first&.dig(:model)
            st = id && map[id]
            st ||= map.values.find { |s| !instance_alive?(s[:instance]) }
            next unless st && model

            real_id = map.key(st)
            queue_heal(model, real_id, st, 'onEraseEntity')
          end
        end

        def queue_heal(model, entity_id, st, source)
          key = model.guid
          STATE[:watched][key]&.delete(entity_id)
          record = st[:record]
          n = record ? (JSON.parse(record).length rescue 0) : 0
          puts "[ParaFrame] erase ##{entity_id} via #{source}: healing #{n} layer(s)"
          if record && record != '[]'
            (STATE[:heal_queue][key] ||= []) << record
            schedule(model)
          end
        rescue StandardError => e
          puts "[ParaFrame] queue_heal: #{e.class}: #{e.message}"
        end

        # Drops watched entries whose instance is gone, healing each.
        def reconcile_watched(model)
          key = model.guid
          map = STATE[:watched][key] || {}
          map.to_a.each do |id, st|
            next if instance_alive?(st[:instance])

            queue_heal(model, id, st, 'reconcile')
          end
        end

        def instance_alive?(inst)
          inst && inst.valid?
        rescue StandardError
          false
        end

        # After undo/redo the model already holds the correct state —
        # reacting would fight the user's undo. Go quiet briefly and
        # refresh every cache to the restored reality.
        def transaction_jump(model)
          key = model.guid
          STATE[:quiet_until][key] = Time.now + UNDO_QUIET
          STATE[:dirty][key] = {}
          STATE[:heal_queue][key] = []
          UI.start_timer(0.05, false) { rescan(model) if model.valid? }
        end

        # ---------------------------------------------------- processing

        def schedule(model)
          key = model.guid
          return if STATE[:timer][key]

          STATE[:timer][key] = true
          UI.start_timer(DEBOUNCE, false) do
            STATE[:timer][key] = false
            begin
              process(model)
            rescue StandardError => e
              puts "[ParaFrame] observer processing failed: #{e.class}: " \
                   "#{e.message}\n#{e.backtrace.join("\n")}"
            end
          end
        end

        def process(model)
          key = model.guid
          quiet = STATE[:quiet_until][key] && Time.now < STATE[:quiet_until][key]

          heals = STATE[:heal_queue][key] || []
          STATE[:heal_queue][key] = []
          dirty = (STATE[:dirty][key] || {}).keys
          STATE[:dirty][key] = {}
          return if quiet

          # Erased components: heal their openings from the cached records.
          heals.each do |json|
            records = begin
              JSON.parse(json)
            rescue JSON::ParserError
              []
            end
            Cutter.heal_records(model, records)
          end

          # Moved/scaled components: recut where the transform really
          # changed (attribute writes also fire onChangeEntity — ignore).
          dirty.each do |entity_id|
            st = STATE[:watched].dig(key, entity_id)
            next unless st

            inst = st[:instance]
            next unless inst&.valid?

            new_matrix = inst.transformation.to_a
            next if matrices_equal?(new_matrix, st[:matrix])

            # A scale gesture also needs the DC engine to re-space the
            # component's internals (formulas read live size) before the
            # opening is recut to the new outline.
            DCBridge.redraw(inst, undo: true) if scale_changed?(new_matrix, st[:matrix])
            Cutter.recut(inst)
            st[:matrix] = inst.transformation.to_a
            st[:record] = Cutter.raw_record(inst)
          end
        end

        # ------------------------------------------------------- helpers

        def matrices_equal?(a, b)
          return false unless a && b

          a.each_index.all? { |i| (a[i] - b[i]).abs < 1e-9 }
        end

        # Compares the axis scale factors of two 4x4 matrices.
        def scale_changed?(a, b)
          [0, 4, 8].any? do |o|
            la = Math.sqrt(a[o]**2 + a[o + 1]**2 + a[o + 2]**2)
            lb = Math.sqrt(b[o]**2 + b[o + 1]**2 + b[o + 2]**2)
            (la - lb).abs > 1e-6
          end
        end

        private

        # Creates each observer object exactly once per session, so
        # repeated attach/watch calls pass the same object to add_observer.
        def singleton(name)
          STATE[:singletons][name] ||= yield
        end

      end # class << self
    end # module Observers
  end # module ParaFrame
end # module Kopji
