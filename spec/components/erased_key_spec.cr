require "../spec_helper"

# An aggregate that records what it managed to read, so a hole in the stream is
# visible in the resulting state rather than only in the version counter.
class SecretAggregate < ES::Aggregate
  @@type = "SecretAggregate"

  struct State < ES::Aggregate::State
    property secrets : Array(String) = [] of String
  end

  getter state : State

  def initialize(
    aggregate_id : UUID,
    @event_store : ES::EventStore,
    @event_handlers : ES::EventHandlers? = nil,
    @reject_unhandled_events = true,
  )
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  def apply(event : EncryptedEvent)
    @state.increase_version(event.header.aggregate_version)
    @state.secrets << event.body.as(EncryptedEvent::Body).secret
  end
end

class SecretProjection < ES::Projection
  class_property seen : Array(String) = [] of String

  def apply(event : EncryptedEvent)
    SecretProjection.seen << event.body.as(EncryptedEvent::Body).secret
  end
end

# Builds a two-event stream under two different keys and erases the first
private def stream_with_one_key_destroyed
  encryption = test_encryption
  store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
  aggregate_id = UUID.v7

  erased_key = encryption.create_key
  kept_key = encryption.create_key

  store.append(EncryptedEvent.new(
    actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
    aggregate_version: 1, encryption_key_id: erased_key, secret: "personal data"
  ))
  store.append(EncryptedEvent.new(
    actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
    aggregate_version: 2, encryption_key_id: kept_key, secret: "still readable"
  ))

  encryption.destroy_key(erased_key)
  {store, aggregate_id}
end

describe ES::Aggregate do
  describe "#hydrate over an encrypted stream" do
    it "rebuilds state from events it can read" do
      encryption = test_encryption
      store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
      aggregate_id = UUID.v7

      store.append(EncryptedEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 1, encryption_key_id: encryption.create_key, secret: "first"
      ))
      store.append(EncryptedEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 2, encryption_key_id: encryption.create_key, secret: "second"
      ))

      aggregate = SecretAggregate.new(aggregate_id, store, test_event_handlers)
      aggregate.hydrate

      aggregate.state.secrets.should eq(["first", "second"])
      aggregate.state.version.should eq(2)
    end

    it "raises NotFound across a hole left by an erasure — deletion is the answer, no special signal" do
      store, aggregate_id = stream_with_one_key_destroyed

      expect_raises(ES::Exception::NotFound) do
        SecretAggregate.new(aggregate_id, store, test_event_handlers).hydrate
      end
    end
  end
end

describe ES::Projection do
  describe "#replay over an encrypted stream" do
    it "skips an event whose key was destroyed, logs it, and keeps projecting the rest" do
      store, _ = stream_with_one_key_destroyed
      SecretProjection.seen.clear

      SecretProjection.new(
        event_handlers: test_event_handlers,
        event_store: store,
        projection_database: DBMock.open,
      ).replay(truncate: true)

      # Only selected events may carry PII and be encrypted at all — a key shredded
      # for one of them must not break every other projector reading the stream.
      SecretProjection.seen.should eq(["still readable"])
    end
  end
end

# Mirrors a real pattern from the financial-transaction example: an event that
# carries nothing encrypted itself, but whose #apply hydrates an aggregate to read
# a value recorded by an earlier event in the same stream — one that may since have
# had its key destroyed. `Events::TransactionAccepted` hydrates back to
# `Events::TransactionInitiated` exactly this way.
class HydratingProjection < ES::Projection
  class_property seen : Array(String) = [] of String

  def apply(event : PlainEvent)
    aggregate = SecretAggregate.new(event.header.aggregate_id, @event_store, @event_handlers)
    aggregate.hydrate
    HydratingProjection.seen << aggregate.state.secrets.last
  end
end

class HydratingInitProjection < ES::Projection
  @@init = true
  class_property seen : Array(String) = [] of String

  protected def table_empty? : Bool
    true
  end

  def apply(event : PlainEvent)
    aggregate = SecretAggregate.new(event.header.aggregate_id, @event_store, @event_handlers)
    aggregate.hydrate
    HydratingInitProjection.seen << aggregate.state.secrets.last
  end
end

describe ES::Projection do
  describe "#replay when #apply itself hits a destroyed key downstream" do
    it "skips the event, logs it, and does not raise out of replay" do
      store, aggregate_id = stream_with_one_key_destroyed
      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 3, secret: "trigger"
      ))
      HydratingProjection.seen.clear

      HydratingProjection.new(
        event_handlers: test_event_handlers,
        event_store: store,
        projection_database: DBMock.open,
      ).replay(truncate: true)

      HydratingProjection.seen.should be_empty
    end
  end

  describe "#init when #apply itself hits a destroyed key downstream" do
    it "does not crash the spawned fiber" do
      store, aggregate_id = stream_with_one_key_destroyed
      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 3, secret: "trigger"
      ))
      HydratingInitProjection.seen.clear

      projection = HydratingInitProjection.new(
        event_handlers: test_event_handlers,
        event_store: store,
        projection_database: DBMock.open,
      )
      projection.init
      Fiber.yield

      HydratingInitProjection.seen.should be_empty
    end
  end
end

describe ES::EventHandlers do
  describe "#materialize" do
    it "rebuilds a typed event from a stored one" do
      encryption = test_encryption
      store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "materialized"
      )
      store.append(event)

      rebuilt = test_event_handlers.materialize(store.fetch_event(event.header.event_id))

      rebuilt.should be_a(EncryptedEvent)
      rebuilt.body.as(EncryptedEvent::Body).secret.should eq("materialized")
      rebuilt.header.encryption_key_id.should eq(event.header.encryption_key_id)
    end
  end
end
