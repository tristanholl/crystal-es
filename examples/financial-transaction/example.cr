require "db"
require "pg"

require "../../src/crystal-es"

require "./test_event"

# Initializing the store (the example is using postgres)
db = DB.open("postgres://es:es@localhost:33333/eventstore?max_pool_size=10")
ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
store = ES::Config.event_store
queue = ES::QueueAdapters::Postgres.new("default", db)

require "option_parser"

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
1000.times do |i|
  event = TransactionInitiated.new(
  creditor_account: creditor_account,
  debtor_account: debtor_account,
  amount: i
)

  store.append(event)
end