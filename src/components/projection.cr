# TODO: Implement projector
module ES
  abstract class Projection
    @event_handlers : ES::EventHandlers
    @event_store : ES::EventStore
    @projection_database : DB::Database

    def initialize(
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
      @event_store : ES::EventStore = ES::Config.event_store,
      @projection_database : DB::Database = ES::Config.projection_database
    )
      @event_id = UUID.v7
    end

    def initialize(
      @event_id : UUID,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
      @event_store : ES::EventStore = ES::Config.event_store,
      @projection_database : DB::Database = ES::Config.projection_database
    )
    end

    def call(event : ES::Event)
      @event_id = event.header.event_id
      apply(event)
    end

    # This method catches all unhandled events
    protected def apply(event : ES::Event)
    end
  end
end
