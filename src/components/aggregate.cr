module ES
  abstract class Aggregate
    # State struct of the aggregate
    abstract struct State
      # Properties of the aggregate
      getter aggregate_id : UUID
      getter aggregate_type : String
      getter aggregate_version : Int32

      # Initialize the state of the aggregate
      def initialize(@aggregate_id)
        @aggregate_version = 0
        @aggregate_type = "undefined"
      end

      # Increase the current version of the aggregate without applying any business logic
      def increase_version(version : Int32)
        raise ES::Exception::InvalidState.new("Incomplete version stream for aggregate '#{@aggregate_id}', provided version: '#{version}', expected version: '#{next_version}'") if version != next_version
        @aggregate_version = version
      end

      # Return the next version for the given aggregate state
      def next_version
        @aggregate_version + 1
      end
    end

    @@type = "undefined"
    @event_store : ES::EventStore
    # @event_handlers : ES::EventHandlers
    @strict_versioning = true

    # Returns the aggregate type on class level
    def self.type
      @@type
    end

    # Initialize the aggregate
    # - with an event store instance
    # - the strict versioning flag
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @strict_versioning = true
    )
    end

    # Applying an unspecified event to the aggregate
    def apply(event : ES::Event)
      if @strict_versioning
        raise ES::Exception::Framework.new("Event not handled: '#{event.class}' in aggregate '#{event.header.aggregate_type}'")
      else
        @state.increase_version(event.header.aggregate_version)
      end
    end
  end
end
