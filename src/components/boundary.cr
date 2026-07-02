module ES
  # Builds a dynamic consistency boundary for a command.
  #
  # A boundary collects the sequences (aggregates and/or tags) a decision is based on,
  # captures the version at which each sequence was read, and stages new events for an
  # atomic conditional append. On commit, the event store rejects the batch with
  # ES::Exception::Conflict if any member sequence advanced since it was loaded.
  class Boundary
    getter pending : Array(ES::Event)

    def initialize(@event_store : ES::EventStore = ES::Config.event_store)
      @expected = Hash(String, Int32).new
      @staged_counts = Hash(String, Int32).new
      @pending = Array(ES::Event).new
    end

    # Hydrates an aggregate into the boundary; aggregates without events join at version 0
    def load(aggregate : ES::Aggregate) : ES::Aggregate
      begin
        aggregate.hydrate
      rescue ES::Exception::NotFound
      end

      track(aggregate.state.aggregate_id.to_s, aggregate.state.version)
      aggregate
    end

    # Folds the event stream of a sequence key (aggregate_id or tag) into caller-supplied
    # state and enlists the sequence at the version that was read
    def load(tag : String, & : ES::EventStore::Event ->)
      last = 0

      @event_store.fetch_events(tag).each do |event|
        yield event
        version = sequence_version(event.header, tag)
        last = version unless version.nil?
      end

      track(tag, last)
    end

    # Enlists a sequence at a known version without folding its events (read-only assert)
    def track(key : String, version : Int32)
      @expected[key] = version
    end

    # Returns the version to stamp on the next event for the given sequence key,
    # accounting for events already staged in this boundary
    def next_version(key : String) : Int32
      base = @expected[key]? || @event_store.last_version(key)
      base + @staged_counts.fetch(key, 0) + 1
    end

    # Returns the next version for the given aggregate's sequence
    def next_version(aggregate : ES::Aggregate) : Int32
      next_version(aggregate.state.aggregate_id.to_s)
    end

    # Stages an event for the atomic commit
    def stage(event : ES::Event)
      event.memberships.each_key do |key|
        @staged_counts[key] = @staged_counts.fetch(key, 0) + 1
      end

      @pending << event
    end

    # Atomically appends all staged events, conditioned on every loaded sequence still
    # being at the version it was read at. Raises ES::Exception::Conflict otherwise.
    def commit
      @event_store.append(@pending, ES::AppendCondition.new(@expected))

      # Advance the boundary to the committed versions so it can be reused
      @pending.each do |event|
        event.memberships.each do |key, version|
          @expected[key] = version if @expected.fetch(key, 0) < version
        end
      end

      @pending.clear
      @staged_counts.clear
    end

    # Returns the version of the event within the given sequence, or nil if it is not a member
    private def sequence_version(header : JSON::Any, tag : String) : Int32?
      return header["aggregate_version"].as_i if header["aggregate_id"].to_s == tag

      if tags = header["tags"]?
        tags[tag]?.try(&.as_i)
      end
    end
  end
end
