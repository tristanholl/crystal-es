# The command: a pure data record expressing the intent to process an
# initiated transaction. It carries only the target aggregate.
struct Commands::ProcessTransaction < ES::Command
end

# The handler: hydrates the aggregate, enforces state invariants, and appends
# the resulting event. Constructed and called directly
class Commands::ProcessTransactionHandler < ES::CommandHandler(Commands::ProcessTransaction)
  def handle(command : Commands::ProcessTransaction)
    # Build the Transaction aggregate
    aggregate = Aggregate.new(
      command.aggregate_id,
      event_store: @event_store,
      event_handlers: @event_handlers
    )
    aggregate.hydrate

    # Return if the aggregate is in a final state
    return if aggregate.state.accepted?

    # Extract aggregate state attributes to local variables
    next_version = aggregate.state.next_version
    transaction_amount = aggregate.state.amount
    encryption_key_id = aggregate.state.encryption_key_id

    raise ES::Exception::InvalidState.new("Aggregate has no encryption key, but origin event requires it") if encryption_key_id.nil?
    raise ES::Exception::InvalidState.new("Invalid transaction amount: '#{transaction_amount}'") if transaction_amount.nil?

    # Accept the transaction if it has an amount <= 1000
    event = if transaction_amount <= 1000
              Events::TransactionAccepted.new(
                actor_id: nil,
                command_handler: self.class.to_s,
                aggregate_id: command.aggregate_id,
                aggregate_version: next_version,
              )
            else
              Events::TransactionRejected.new(
                actor_id: nil,
                command_handler: self.class.to_s,
                reason: "Amount above threshold of 1000: '#{transaction_amount}'",
                aggregate_id: command.aggregate_id,
                aggregate_version: next_version,
              )
            end

    @event_store.append(event)
  end
end
