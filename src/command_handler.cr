module ES
  # Impure shell that wires a pure Decider to the event store.
  #
  # C — command type
  # S — state type
  # E — event type; must be a subtype of ES::Event so events can be appended
  #
  # Optimistic locking is provided by the store's UNIQUE(aggregate_id, version)
  # constraint — no separate expected-version parameter is needed. The decider
  # embeds the next version (read from state.next_version) into each emitted
  # event's header; a concurrent writer that used the same version causes the
  # DB to raise a constraint violation.
  #
  # `parse` converts a raw ES::EventStore::Event into the typed domain event E.
  # Keeping it as a caller-supplied proc decouples the handler from EventHandlers
  # and lets the caller control the registry and casting strategy.
  class CommandHandler(C, S, E)
    def initialize(
      @decider : ES::Decider(C, S, E),
      @store : ES::EventStore,
      @parse : Proc(ES::EventStore::Event, E),
    ); end

    def handle(aggregate_id : UUID, command : C) : ES::Decision(E)
      raw    = @store.fetch_events(aggregate_id)
      typed  = raw.map { |e| @parse.call(e) }
      state  = @decider.fold(@decider.initial_state, typed)
      outcome = @decider.decide(command, state)

      if outcome.accepted?
        outcome.events.each { |e| @store.append(e) }
      end

      outcome
    end
  end
end
