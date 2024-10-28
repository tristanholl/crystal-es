require "db"
require "pg"
require "option_parser"

require "../../src/crystal-es"

require "./aggregate"
require "./commands/process_transaction"
require "./events/transaction_accepted"
require "./events/transaction_initiated"
require "./events/transaction_rejected"
require "./projections/ledger"

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
store.setup

# Initialize queue
queue = ES::QueueAdapters::Postgres.new("default", db)
store.setup

# Intialize projection database
ES::Config.projection_database = db
projection_database = ES::Config.projection_database

# Initialize projection
p = Projections::Ledger.new
p.setup

# Initialize event bus
ES::Config.event_bus = ES::EventBus(ES::Command.class | ES::Projection.class).new(store, event_handlers)
# ES::Config.event_bus = ES::EventBus(ES::Command.class | ES::Projection.class).new(store, event_handlers)
bus = ES::Config.event_bus

# Subscribing command handlers to events
bus.subscribe(Events::TransactionAccepted, Projections::Ledger)
bus.subscribe(Events::TransactionInitiated, [
  Commands::ProcessTransaction,
  Projections::Ledger,
])
bus.subscribe(Events::TransactionRejected, Projections::Ledger)

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

    if event_bus.publish(event)
      queue.archive(message.msg_id)
    end
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
creditor_account = UUID.new("01929fef-2e55-742f-b151-000000acc100")
debtor_account = UUID.new("01929fef-2e55-742f-b151-000000acc200")

# Create 1000 transactions
10.times do |i|
  event = Events::TransactionInitiated.new(
    creditor_account: creditor_account,
    debtor_account: debtor_account,
    amount: (i + 1)*333
  )

  store.append(event)
end

puts "Press any key to exit"
gets
