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
require "./decider"

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

ES::Config.event_handlers = ES::EventHandlers.new
event_handlers = ES::Config.event_handlers

event_handlers.register(Events::TransactionAccepted)
event_handlers.register(Events::TransactionInitiated)
event_handlers.register(Events::TransactionRejected)

db = DB.open("postgres://es:es@localhost:33333/eventstore?max_pool_size=10")

ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
store = ES::Config.event_store
store.setup

queue = ES::QueueAdapters::Postgres.new("default", db)
store.setup

ES::Config.projection_database = db
projection_database = ES::Config.projection_database

p = Projections::Ledger.new
p.setup

# ---------------------------------------------------------------------------
# New handler — replaces bus subscription for ProcessTransaction.
# The event bus is now used only for projections.
# ---------------------------------------------------------------------------

transaction_handler = build_transaction_handler(store, event_handlers)

ES::Config.event_bus = ES::EventBus(ES::Command.class | ES::Projection.class).new(store, event_handlers)
bus = ES::Config.event_bus

bus.subscribe(Events::TransactionAccepted, Projections::Ledger)
bus.subscribe(Events::TransactionInitiated, Projections::Ledger)
bus.subscribe(Events::TransactionRejected, Projections::Ledger)

# ---------------------------------------------------------------------------
# Queue consumer — routes TransactionInitiated through the new handler
# ---------------------------------------------------------------------------

def process_queue(
  queue : ES::Queue,
  store : ES::EventStore,
  event_handlers : ES::EventHandlers,
  event_bus : ES::EventBus,
  handler : ES::CommandHandler(TransactionCommand, Aggregate::State, TransactionEvent),
)
  channel = queue.listen

  loop do
    message = channel.receive

    es_event = store.fetch_event(message.header.event_id)
    h = ES::Event::Header.from_json(es_event.header.to_json)
    event = event_handlers.event_class(h.event_handle).new(h, es_event.body)

    # Dispatch TransactionInitiated through the new decider + handler path.
    # All other events are published to the bus for projections.
    case event
    when Events::TransactionInitiated
      aggregate_id = event.header.aggregate_id
      handler.handle(aggregate_id, ProcessTransaction.new(aggregate_id: aggregate_id))
      event_bus.publish(event)
    else
      event_bus.publish(event)
    end

    queue.archive(message.msg_id)
  end
end

spawn process_queue(queue, store, event_handlers, bus, transaction_handler)

# ---------------------------------------------------------------------------
# CLI / setup
# ---------------------------------------------------------------------------

OptionParser.parse do |parser|
  parser.banner = "Welcome to transaction example of the crystal-es lib!"

  parser.on "-s", "--setup", "Setup eventstore and queue" do
    puts "Initializing event store..."
    store.setup
    puts "Initializing queue..."
    queue.setup
    puts "Done!"
    exit
  end
end

creditor_account = UUID.new("01929fef-2e55-742f-b151-000000acc100")
debtor_account   = UUID.new("01929fef-2e55-742f-b151-000000acc200")

10.times do |i|
  event = Events::TransactionInitiated.new(
    creditor_account: creditor_account,
    debtor_account: debtor_account,
    amount: (i + 1)*333_i64
  )

  store.append(event)
end

puts "Press any key to exit"
gets
