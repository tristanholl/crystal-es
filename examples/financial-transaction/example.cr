require "db"
require "pg"
require "option_parser"

require "../../src/crystal-es"

require "./aggregate"
require "./commands/process_transaction"
require "./reactors/on_transaction_initiated"
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
db = DB.open("postgres://es:es@database:5432/eventstore?max_pool_size=10")

# Initializing payload encryption. The application key is the one secret this
# example manages directly — the library never reads it from the environment
# itself. It must stay stable across runs: the event store and key store persist
# in postgres (`setup` is a noop once the tables exist), so a fresh random key on
# every restart would leave every previously wrapped data key unreadable, even
# though nothing was actually shredded.
application_key_bytes = if encoded = ENV["APPLICATION_ENCRYPTION_KEY"]?
                          Base64.decode(encoded)
                        else
                          generated = ES::PayloadCipher.random_key
                          STDERR.puts "APPLICATION_ENCRYPTION_KEY not set; generated one for this run."
                          STDERR.puts "Export it before the next run to keep reading what this run writes:"
                          STDERR.puts "  export APPLICATION_ENCRYPTION_KEY=#{Base64.strict_encode(generated)}"
                          generated
                        end
application_key = ES::ApplicationEncryptionKeyManager.new(application_key_bytes)
key_store = ES::KeyStoreAdapters::Postgres.new(db)
key_store.setup

ES::Config.encryption = ES::EncryptionKeyManager.new(key_store, application_key)
encryption = ES::Config.encryption

# Initialize event store (picks up ES::Config.encryption automatically)
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
ES::Config.event_bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(store, event_handlers)
bus = ES::Config.event_bus

# Subscribing reactors and projections to events
bus.subscribe(Events::TransactionAccepted, Projections::Ledger)
bus.subscribe(Events::TransactionInitiated, [
  Reactors::OnTransactionInitiated,
  Projections::Ledger,
])
bus.subscribe(Events::TransactionRejected, Projections::Ledger)

def process_queue(
  queue : ES::Queue,
  store : ES::EventStore,
  event_handlers : ES::EventHandlers,
  event_bus : ES::EventBus,
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

enc_key_id = UUID.new(encryption.create_key)

# Create 1000 transactions. TransactionInitiated is declared `encrypted: true`
# (see events/transaction_initiated.cr), so each one needs its own data key —
# destroying that key later erases both accounts named in the body.
10.times do |i|
  event = Events::TransactionInitiated.new(
    actor_id: nil,
    command_handler: "example",
    encryption_key_id: enc_key_id,
    amount: (i + 1)*333,
    creditor_account: creditor_account,
    debtor_account: debtor_account
  )

  store.append(event)
end

puts "Press any key to exit"
gets
