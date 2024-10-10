require "db"
require "pg"

require "../src/crystal-es"

db = DB.open("postgresql://es:es@localhost:33333/eventstore")
ES::Config.event_store = ES::EventStores::Postgres.new(db)
es = ES::Config.event_store
es.setup

db_queue = DB.open("postgresql://es:es@localhost:33333/eventstore")
qq = ES::Queues::Postgres.new(db)
qq.setup

ES::Config.event_handlers = ES::EventHandlers.new
eh = ES::Config.event_handlers

class Ev1 < ES::Event
  @@type = "RandomEvent"
  @@handle = "ev1"

  # Data Object for the body of the event
  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize(@comment)
    end
  end

  def initialize(comment = "")
    @header = Header.new(
      aggregate_id: UUID.v7,
      aggregate_type: @@type,
      aggregate_version: 1,
      event_handle: @@handle
    )
    @body = Body.new(comment)
  end

  def initialize(@header : ES::Event::Header, body : JSON::Any)
    # Parse body
    @body = Body.from_json(body.to_json)
  end
end
eh.register(Ev1)

ev1 = Ev1.new

es.append(ev1)

queue : Channel(ES::Queue::Entry)
queue = qq.listen("eventstore_queue")
loop do
  message = queue.receive

  event_id = message.header.event_id
  es_event = es.fetch_event(event_id)

  h = ES::Event::Header.from_json(es_event.header.to_json)
  event = ES::Config.event_handlers.event_class(h.event_handle).new(h, es_event.body)
  
  # if @eventbus.publish(event)
  #   @queue.archive(message.msg_id) # delete
  # else
  #   @queue.archive(message.msg_id)
  #   # Log.error { "Invalid processing result for '#{message.header.event_handle}'" }
  # end

  # Send to event bus
end
