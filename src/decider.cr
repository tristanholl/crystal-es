module ES
  # Pure functional contract for event-sourced decision logic.
  #
  # C — command type (data record or union of data records)
  # S — state type (value type / struct)
  # E — event type (ES::Event subclass or union thereof)
  #
  # Implementations must be free of I/O: no event-store reads or writes.
  # The handler is the only component that touches the store.
  module Decider(C, S, E)
    abstract def initial_state : S
    abstract def decide(command : C, state : S) : ES::Decision(E)
    abstract def evolve(state : S, event : E) : S

    # Reduces evolve over an arbitrary event slice starting from state.
    # Works on any starting state and any contiguous event subsequence —
    # it does not assume the full stream from the aggregate's initial state.
    def fold(state : S, events : Enumerable(E)) : S
      events.reduce(state) { |s, e| evolve(s, e) }
    end
  end
end
