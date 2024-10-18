class Events::TransactionAccepted < ES::Event
  @@aggregate = "Transaction"
  @@handle = "transaction.accepted"

  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize; end
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
    command_handler : String
  )
    @header = Header.new(
      aggregate_id: aggregate_id,
      aggregate_type: @@aggregate,
      aggregate_version: aggregate_version,
      command_handler: command_handler,
      event_handle: @@handle
    )
    @body = Body.new
  end
end
