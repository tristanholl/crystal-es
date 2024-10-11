# TODO: Implement projector
module ES
  abstract class Projection
    # @projection_db : DB::Database
    # @event_store : ES::EventStore
    # @event_handlers : ES::EventHandlers

    # def initialize(
    #   @projection_db : DB::Database = ES::Config.projection_db,
    #   @event_store : ES::EventStore = ES::Config.event_store,
    #   @event_handlers : ES::EventHandlers = ES::Config.event_handlers
    # )
    #   @event_id = UUID.v7
    # end

    # def initialize(
    #   @event_id : UUID,
    #   @projection_db : DB::Database = ES::Config.projection_db,
    #   @event_store : ES::EventStore = ES::Config.event_store,
    #   @event_handlers : ES::EventHandlers = ES::Config.event_handlers
    # )
    # end

    # def call(event : ES::Event)
    #   @event_id = event.header.event_id
    #   apply(event)
    # end

    # # This method catches all unhandled events
    # protected def apply(event : ES::Event)
    # end
  end
end
