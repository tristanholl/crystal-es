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
end

ev1 = Ev1.new

es.append(ev1)

puts "A ----------------------------------------"
puts es.fetch_event(ev1.header.event_id)
puts "B ----------------------------------------"
# puts es.fetch_event(UUID.new("0192771d-6a3a-7481-81d4-b17888ef4249"))
puts "C ----------------------------------------"
puts es.fetch_events(ev1.header.aggregate_id)


queue : Channel(ES::Queue::Entry)
queue = qq.listen("eventstore_queue")
loop do
  message = queue.receive

  puts message
end