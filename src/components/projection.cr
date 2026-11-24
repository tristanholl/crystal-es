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
    @@atomic : Bool = false

    # The connection of the transaction a subscription applies a batch in,
    # while it does; see `write`
    @write_connection : DB::Connection? = nil

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

    # Whether every write of this projection goes through `write`, declared
    # with `define_projection(..., atomic: true)`. `ES::Subscriptions` then
    # applies events in batches, each in one transaction with the
    # projection's position, so every event is applied exactly once. Without
    # it, a subscription applies one event at a time and records the position
    # after it, so an event may be applied again after a crash.
    def self.atomic? : Bool
      @@atomic
    end

    # The schema of the projection's table, `public` if it names none
    def self.table_schema : String
      parts = @@table.split('.')
      parts.size >= 2 ? parts[0] : "public"
    end

    # Runs the block with a connection to write the projection's rows on. While
    # `ES::Subscriptions` applies a batch, that is the connection of the
    # batch's transaction, so the rows commit together with the projection's
    # position; otherwise the block runs in a transaction of its own.
    #
    # ```
    # apply(OrderPlaced) do
    #   write do |connection|
    #     connection.exec %(INSERT INTO "shop"."orders" (id, total) VALUES ($1, $2)), aggregate_id, body.total
    #   end
    # end
    # ```
    protected def write(& : DB::Connection ->)
      if connection = @write_connection
        yield connection
      else
        @projection_database.transaction { |tx| yield tx.connection }
      end
    end

    # :nodoc:
    # Makes `write` use `connection` while the block runs
    def writing_on(connection : DB::Connection, &)
      @write_connection = connection
      yield
    ensure
      @write_connection = nil
    end

    def call(event : ES::Event)
      @event_id = event.header.event_id
      apply(event)
    end

    def replay(truncate : Bool, until_event_id : UUID? = nil)
      raise ES::Exception::InvalidState.new("replay requires explicit confirmation: pass truncate: true to truncate the projection table before replaying") unless truncate
      self.truncate if !self.class.table.empty?

      @event_store.each_event(until_event_id: until_event_id) do |es_event|
        handle = es_event.header["event_handle"].as_s
        next unless @event_handlers.registered?(handle)

        process(es_event)
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
          handle = es_event.header["event_handle"].as_s
          next unless @event_handlers.registered?(handle)

          process(es_event)
        end
      end
    end

    # Applies one stored event, tolerating a key destroyed anywhere in the work
    # `apply` does for it — not just the event's own body (already handled by
    # `EventStore#each_event`), but also something `apply` reaches for, like an
    # `Aggregate#hydrate` call that walks back into a stream holding a since-shredded
    # event. Only some events carry encryption at all, so one destroyed key must not
    # take down a projector's replay of everything else: log a warning and move on.
    private def process(es_event : ES::EventStore::Event)
      call(@event_handlers.materialize(es_event))
    rescue ex : ES::Exception::NotFound
      Log.warn { "Skipping event '#{es_event.header["event_id"]?}' (handle '#{es_event.header["event_handle"]?}') in #{self.class.name}: #{ex.message}" }
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
