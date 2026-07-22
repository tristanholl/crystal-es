# Reactor: when a transaction is initiated, process it. This is the one bridge
# from the event back to a command — the reactor constructs the command and
# calls its handler directly, synchronously.
class Reactors::OnTransactionInitiated < ES::Reactor
  reacts_to Events::TransactionInitiated

  def call(event : Events::TransactionInitiated)
    Commands::ProcessTransactionHandler.new(
      event_store: @event_store,
      event_handlers: @event_handlers,
    ).handle(
      Commands::ProcessTransaction.new(aggregate_id: event.header.aggregate_id)
    )
  end
end
