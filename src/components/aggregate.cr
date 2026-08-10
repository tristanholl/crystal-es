module ES
  abstract class Aggregate
    # State struct of the aggregate
    abstract struct State
      # Properties of the aggregate
      getter aggregate_id : UUID
      getter aggregate_type : String = "undefined"
      getter aggregate_version : Int32 = 0

      # Initialize the state of the aggregate
      def initialize(@aggregate_id); end

      # Increase the current version of the aggregate without applying any business logic
      def increase_version(version : Int32)
        raise ES::Exception::InvalidState.new("Incomplete version stream for aggregate '#{@aggregate_id}', provided version: '#{version}', expected version: '#{next_version}'") if version != next_version
        @aggregate_version = version
      end

      # Return the next version for the given aggregate state
      def next_version
        @aggregate_version + 1
      end

      # Sets the type of the aggregate
      def set_type(type : String)
        @aggregate_type = type
      end

      # Returns the aggregate version
      def version : Int32
        @aggregate_version
      end
    end

    # Enforce implementation of state getter in child classes
    abstract def state : State

    @@type = "undefined"
    @event_store : ES::EventStore
    @reject_unhandled_events = true

    # Resolved lazily rather than in the constructor, so subclasses that define
    # their own `initialize` (the common case) keep working and a test aggregate
    # never has to configure a global just to exist.
    @event_handlers : ES::EventHandlers? = nil

    # Returns the aggregate type on class level
    def self.type
      @@type
    end

    # Initialize the aggregate
    # - with an event store instance
    # - the strict versioning flag
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @reject_unhandled_events = true,
      @event_handlers : ES::EventHandlers? = nil,
    )
    end

    # The registry used to rebuild stored events, defaulting to the configured one
    def event_handlers : ES::EventHandlers
      @event_handlers ||= ES::Config.event_handlers
    end

    # Handle events up to a certain version
    def apply(
      event : ES::EventStore::Event,
      up_to_version : Int32,
    )
      h = ES::Event::Header.from_json(event.header.to_json)
      return if h.aggregate_version > up_to_version

      apply(event_handlers.materialize(event, h))
    end

    # Applying an unspecified event to the aggregate
    def apply(event : ES::Event)
      if @reject_unhandled_events
        raise ES::Exception::InvalidEventStream.new("Event not handled: '#{event.class}' in aggregate '#{event.header.aggregate_type}'")
      else
        @state.increase_version(event.header.aggregate_version)
      end
    end

    # Hydrate the aggregate state from events
    def hydrate(version : Int32 = Int32::MAX)
      es = @event_store
      raise ES::Exception::DependencyUnavailable.new("Eventstore not available") if es.nil?

      events = es.fetch_events(@state.aggregate_id)
      raise ES::Exception::NotFound.new("Aggregate '#{@state.aggregate_id}' of type '#{@state.aggregate_type}' not found") if events.empty?

      events.each do |event|
        apply(event, up_to_version: version)
      end
    end
  end
end
