module ES
  abstract class Aggregate
    # State struct of the aggregate
    abstract struct State
      # Properties of the aggregate
      getter aggregate_id : UUID
      getter aggregate_type : String
      getter aggregate_version : Int32

      def initialize(@aggregate_id)
        @aggregate_version = 0
        @aggregate_type = "undefined"
      end

      def increase_version(version : Int32)
        raise ES::Exception::Framework.new("Incomplete version stream for aggregate '#{@aggregate_id}', provided version: '#{version}', expected version: '#{next_version}'") if version != next_version
        @aggregate_version = version
      end

      def next_version
        @aggregate_version + 1
      end
    end

    @@type = "undefined"
    @event_store : ES::EventStore
    # @event_handlers : ES::EventHandlers
    @strict_versioning = true

    def self.type
      @@type
    end

    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store
    )
    end

    # Handle an event
    def apply(event : ES::Event)
      if @strict_versioning
        raise ES::Exception::Framework.new("Event not handled: '#{event.class}' in aggregate '#{event.header.aggregate_type}'")
      else
        @state.increase_version(event.header.aggregate_version)
      end
    end
  end
end
