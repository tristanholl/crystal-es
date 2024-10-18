require "db"
require "pg"
require "option_parser"

require "../../src/crystal-es"

require "./aggregate"
require "./commands/process_transaction"
require "./events/transaction_accepted"
require "./events/transaction_initiated"
require "./events/transaction_rejected"

# Initializing event handlers
ES::Config.event_handlers = ES::EventHandlers.new
event_handlers = ES::Config.event_handlers

event_handlers.register(Events::TransactionAccepted)
event_handlers.register(Events::TransactionInitiated)
event_handlers.register(Events::TransactionRejected)

# Initializing the store (the example is using postgres)
db = DB.open("postgres://es:es@localhost:33333/eventstore?max_pool_size=10")

# Initialize event store
ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
store = ES::Config.event_store

# Initialize queue
queue = ES::QueueAdapters::Postgres.new("default", db)

# Initialize event bus
ES::Config.event_bus = ES::EventBus(ES::Command.class).new(store, event_handlers)
# ES::Config.event_bus = ES::EventBus(ES::Command.class | ES::Projection.class).new(store, event_handlers)
bus = ES::Config.event_bus

# Subscribing command handlers to events
bus.subscribe(Events::TransactionInitiated, Commands::ProcessTransaction)

def process_queue(
  queue : ES::Queue,
  store : ES::EventStore,
  event_handlers : ES::EventHandlers,
  event_bus : ES::EventBus
)
  channel = queue.listen

  loop do
    message = channel.receive
  
    es_event = store.fetch_event(message.header.event_id)
    h = ES::Event::Header.from_json(es_event.header.to_json)
    event = event_handlers.event_class(h.event_handle).new(h, es_event.body)
    event_bus.publish(event)
  end
end
spawn process_queue(queue, store, event_handlers, bus)

# Parse the for the setup flag
OptionParser.parse do |parser|
  parser.banner = "Welcome to transaction example of the crystal-es lib!"

  parser.on "-s", "--setup", "Setup eventstore and queue " do
    puts "Initializing event store..."
    store.setup
    puts "Initializing queue..."
    queue.setup
    puts "Done!"
    exit
  end
end

# The involved accounts are addressed with UUIDs
creditor_account = UUID.v7
debtor_account = UUID.v7

# Create 1000 transactions
10.times do |i|
  event = Events::TransactionInitiated.new(
    creditor_account: creditor_account,
    debtor_account: debtor_account,
    amount: i*333
  )

  store.append(event)
end

puts "Press any key to exit"
gets