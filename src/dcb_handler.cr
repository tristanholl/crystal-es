module ES
  # Tag-query type for DCB-style reads.
  # A tag set describes the boundary over which state is assembled — it may
  # span multiple aggregate streams, unlike the aggregate-bounded CommandHandler.
  struct TagQuery
    getter tags : Array(String)

    def initialize(@tags : Array(String)); end
  end

  # DCB-ready handler — assembles state from a tag-defined event boundary.
  #
  # Uses the SAME deciders as ES::CommandHandler (TransactionDecider, etc.)
  # without any modification, proving the decider is boundary-agnostic.
  #
  # C — command type
  # S — state type
  # E — event type
  #
  # The store must support read_by_tags and append_if_unchanged when this
  # handler is used in production.  Specs exercise it via an in-memory
  # implementation of those methods.
  #
  # NOTE: This class compiles and is ready to use, but requires the tags[] +
  # GIN-indexed read path in the event store (tracked separately).  It can
  # be deferred until that work is scheduled — Phases 0–5 stand alone.
  class DcbHandler(C, S, E)
    # Minimal tag-store interface — a subset of ES::EventStore extended with
    # DCB-specific operations.  Concrete implementations (Postgres + GIN index,
    # InMemory for tests) satisfy this interface.
    module TagStore
      abstract def read_by_tags(query : ES::TagQuery) : {Array(ES::EventStore::Event), Int64}
      abstract def append_if_unchanged(events : Array(ES::Event), query : ES::TagQuery, position : Int64) : Bool
    end

    def initialize(
      @decider : ES::Decider(C, S, E),
      @store : TagStore,
      @parse : Proc(ES::EventStore::Event, E),
    ); end

    def handle(command : C, boundary : ES::TagQuery) : ES::Decision(E)
      raw_events, position = @store.read_by_tags(boundary)
      typed  = raw_events.map { |e| @parse.call(e) }
      state  = @decider.fold(@decider.initial_state, typed)
      outcome = @decider.decide(command, state)

      if outcome.accepted?
        # Conditional append: fails if any new event matching the tag set was
        # written since we read at `position`.  This is the DCB optimistic-lock
        # equivalent of the aggregate-level UNIQUE(aggregate_id, version) guard.
        @store.append_if_unchanged(
          outcome.events.map { |e| e.as(ES::Event) },
          boundary,
          position
        )
      end

      outcome
    end
  end
end
