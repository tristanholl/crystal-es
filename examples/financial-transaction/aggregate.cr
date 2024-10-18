class Aggregate < ES::Aggregate
  @@type = "Transaction"

  struct State < ES::Aggregate::State
    property amount : Int64?
    property creditor_account : UUID?
    property debtor_account : UUID?

    property accepted : Bool = false
  end

  getter state : State

  def initialize(
    aggregate_id : UUID, 
    @event_store : ES::EventStore, 
    @event_handlers : ES::EventHandlers
  )
    @aggregate_version = 0
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  # Apply 'Events::TransactionInitiated' to the aggregate state
  def apply(event : Events::TransactionInitiated)
    @state.increase_version(event.header.aggregate_version)

    body = event.body.as(Events::TransactionInitiated::Body)

    @state.amount = body.amount
    @state.creditor_account = body.creditor_account
    @state.debtor_account = body.debtor_account
  end

  # Apply 'Events::TransactionAccepted' to the aggregate state
  def apply(event : Events::TransactionAccepted)
    @state.accepted = true
  end
end