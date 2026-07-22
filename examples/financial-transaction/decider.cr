require "./aggregate"
require "./commands/process_transaction"
require "./events/transaction_accepted"
require "./events/transaction_initiated"
require "./events/transaction_rejected"

# Union of all events this aggregate can emit.
# A decide method that tries to return any other event type fails to compile.
alias TransactionEvent = Events::TransactionInitiated |
                         Events::TransactionAccepted  |
                         Events::TransactionRejected

# Pure decider for the Transaction aggregate.
# Contains no I/O — the ES::CommandHandler provides the event-store shell.
class TransactionDecider
  include ES::Decider(TransactionCommand, Aggregate::State, TransactionEvent)

  def initial_state : Aggregate::State
    s = Aggregate::State.new(UUID.v7)
    s.set_type("Transaction")
    s
  end

  # Pure fold — one step of the reduce over the event stream.
  # Uses set_version (not increase_version) so it works on arbitrary starting
  # states, not just the canonical full stream from version 0.
  def evolve(state : Aggregate::State, event : TransactionEvent) : Aggregate::State
    case event
    when Events::TransactionInitiated
      body = event.body.as(Events::TransactionInitiated::Body)
      state.amount           = body.amount
      state.creditor_account = body.creditor_account
      state.debtor_account   = body.debtor_account
      state.aggregate_version = event.header.aggregate_version
    when Events::TransactionAccepted
      state.accepted = true
      state.aggregate_version = event.header.aggregate_version
    when Events::TransactionRejected
      state.rejected = true
      state.aggregate_version = event.header.aggregate_version
    end
    state
  end

  # Pure decision function.  All business rules live here; no store access.
  def decide(command : TransactionCommand, state : Aggregate::State) : ES::Decision(TransactionEvent)
    case command
    when ProcessTransaction
      if state.accepted || state.rejected
        return ES::Decision(TransactionEvent).reject("Transaction already settled")
      end

      amount = state.amount
      return ES::Decision(TransactionEvent).reject("Invalid transaction amount") if amount.nil?

      next_ver = state.next_version

      if amount <= 1000
        ES::Decision(TransactionEvent).accept([
          Events::TransactionAccepted.new(
            aggregate_id: command.aggregate_id,
            aggregate_version: next_ver,
            command_handler: "TransactionDecider",
          ).as(TransactionEvent),
        ])
      else
        ES::Decision(TransactionEvent).accept([
          Events::TransactionRejected.new(
            aggregate_id: command.aggregate_id,
            aggregate_version: next_ver,
            command_handler: "TransactionDecider",
            reason: "Amount above threshold of 1000: '#{amount}'",
          ).as(TransactionEvent),
        ])
      end
    else
      ES::Decision(TransactionEvent).reject("Unknown command type")
    end
  end
end

# Convenience: build a CommandHandler pre-wired to TransactionDecider.
# Callers provide the event store; event_handlers are used only in the parse proc.
def build_transaction_handler(
  store : ES::EventStore,
  event_handlers : ES::EventHandlers,
) : ES::CommandHandler(TransactionCommand, Aggregate::State, TransactionEvent)
  parse = ->(raw : ES::EventStore::Event) {
    h     = ES::Event::Header.from_json(raw.header.to_json)
    klass = event_handlers.event_class(h.event_handle)
    klass.new(h, raw.body).as(TransactionEvent)
  }
  ES::CommandHandler(TransactionCommand, Aggregate::State, TransactionEvent).new(
    TransactionDecider.new, store, parse
  )
end
