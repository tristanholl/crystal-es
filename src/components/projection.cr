# TODO: Implement projector
module ES
  abstract class Projection
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

    def call(event : ES::Event)
      @event_id = event.header.event_id
      apply(event)
    end

    def replay(until_event_id : UUID? = nil)
      @event_store.each_event(until_event_id: until_event_id) do |es_event|
        handle = es_event.header["event_handle"].as_s
        next unless @event_handlers.registered?(handle)
        h = ES::Event::Header.from_json(es_event.header.to_json)
        call(@event_handlers.event_class(handle).new(h, es_event.body))
      end
    end

    # This method catches all unhandled events
    protected def apply(event : ES::Event)
    end
  end
end
