class Events::TransactionRejected < ES::Event
  @@aggregate = "Transaction"
  @@handle = "transaction.rejected"

  struct Body < ES::Event::Body
    include JSON::Serializable

    getter reason : String

    def initialize(@reason : String); end
  end

  def initialize(
    @header : ES::Event::Header,
    body : JSON::Any
  )
    @body = Body.from_json(body.to_json)
  end

  def initialize(
    aggregate_id : UUID,
    aggregate_version : Int32,
    command_handler : String,
    reason : String
  )
    @header = Header.new(
      aggregate_id: aggregate_id,
      aggregate_type: @@aggregate,
      aggregate_version: aggregate_version,
      command_handler: command_handler,
      event_handle: @@handle
    )
    @body = Body.new(reason: reason)
  end
end
