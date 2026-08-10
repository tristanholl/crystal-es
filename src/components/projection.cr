module ES
  abstract class Projection
    include ES::EventDeclaration

    # A projection declares the events it consumes with typed `apply` overloads.
    macro inherited
      macro finished
        define_handles?("apply")
      end
    end

    @@table = ""
    @@init : Bool = false
    @@projection_batch_size : Int64 = 1000_i64

    @event_handlers : ES::EventHandlers
    @event_store : ES::EventStore
    @projection_database : DB::Database

    def initialize(
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
      @event_store : ES::EventStore = ES::Config.event_store,
      @projection_database : DB::Database = ES::Config.projection_database,
    )
      @event_id = UUID.v7
    end

    def initialize(
      @event_id : UUID,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
      @event_store : ES::EventStore = ES::Config.event_store,
      @projection_database : DB::Database = ES::Config.projection_database,
    )
    end

    def self.table
      @@table
    end

    def self.init? : Bool
      @@init
    end

    def self.projection_batch_size : Int64
      @@projection_batch_size
    end

    def call(event : ES::Event)
      @event_id = event.header.event_id
      apply(event)
    end

    def replay(truncate : Bool, until_event_id : UUID? = nil)
      raise ES::Exception::InvalidState.new("replay requires explicit confirmation: pass truncate: true to truncate the projection table before replaying") unless truncate
      self.truncate if !self.class.table.empty?

      @event_store.each_event(until_event_id: until_event_id) do |es_event|
        # An erased event has no body left to project. Skipping keeps read models
        # rebuildable after an erasure, which they have to stay.
        next if es_event.shredded?

        handle = es_event.header["event_handle"].as_s
        next unless @event_handlers.registered?(handle)

        call(@event_handlers.materialize(es_event))
      end
    end

    # If init? is set and the projection table is empty, consume all events from
    # the store in a background fiber until the projection is up to date.
    # The horizon is captured before spawning so the init always terminates,
    # even when the store is under constant write load.
    def init
      return unless self.class.init?
      return unless table_empty?

      horizon = @event_store.last_event_id
      return if horizon.nil?

      spawn do
        @event_store.each_event(until_event_id: horizon, batch_size: self.class.projection_batch_size) do |es_event|
          next if es_event.shredded?

          handle = es_event.header["event_handle"].as_s
          next unless @event_handlers.registered?(handle)

          call(@event_handlers.materialize(es_event))
        end
      end
    end

    protected def table_empty? : Bool
      t = self.class.table
      return false if t.empty?
      @projection_database.query_one("SELECT NOT EXISTS (SELECT 1 FROM #{t} LIMIT 1)", as: Bool)
    end

    # Truncate the projection table and optionally restart the identity sequence
    protected def truncate(restart_identity : Bool = true)
      t = self.class.table
      raise ES::Exception::NotImplemented.new("No table defined for projection '#{self.class.name}'") if t.empty?

      sql = "TRUNCATE TABLE #{t}"
      sql += " RESTART IDENTITY" if restart_identity
      @projection_database.exec sql
    end

    # This method catches all unhandled events
    protected def apply(event : ES::Event)
    end
  end
end
