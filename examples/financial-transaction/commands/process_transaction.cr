class Commands::ProcessTransaction < ES::Command
  def call
    # Build the Transaction aggregate
    aggregate = Aggregate.new(
      @aggregate_id,
      event_store: @event_store,
      event_handlers: @event_handlers
    )
    aggregate.hydrate

    # Return if the aggregate is in a final state
    return true if aggregate.state.accepted

    # Extract aggregate state attributes to local variables
    next_version = aggregate.state.next_version
    transaction_amount = aggregate.state.amount

    raise ES::Exception::InvalidState.new("Invalid transaction amount: '#{transaction_amount}'") if transaction_amount.nil?

    # Accept the transaction if it has an amount <= 1000
    event = if transaction_amount <= 1000
              Events::TransactionAccepted.new(
                aggregate_id: @aggregate_id,
                aggregate_version: next_version,
                command_handler: self.class.to_s,
              )
            else
              Events::TransactionRejected.new(
                aggregate_id: @aggregate_id,
                aggregate_version: next_version,
                command_handler: self.class.to_s,
                reason: "Amount above threshold of 1000: '#{transaction_amount}'"
              )
            end

    @event_store.append(event)
  end
end
