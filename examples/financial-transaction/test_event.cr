class TransactionInitiated < ES::Event
  @@aggregate = "Transaction"
  @@handle = "transaction.initiated"

  struct Body < ES::Event::Body
    include JSON::Serializable

    getter amount : Int64,
    getter creditor_account: UUID
    getter debtor_account : UUID

    def initialize(
      @amount : Int64,
      @creditor_account : UUID,
      @debtor_account : UUID
    ); end
  end

  def initialize(
    @header : ES::Event::Header,
    body : JSON::Any
  )
    @body = Body.from_json(body.to_json)
  end

  def initialize(
    amount : Int64,
    creditor_account : UUID,
    debtor_account : UUID
  )
    @header = Header.new(
      aggregate_id: UUID.v7,
      aggregate_type: @@aggregate,
      aggregate_version: 1,
      command_handler: "test",
      event_handle: @@handle
    )
    @body = Body.new(
      amount: amount, 
      creditor_account: creditor_account, 
      debtor_account: debtor_account
    )
  end
end