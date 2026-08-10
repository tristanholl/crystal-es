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
    @skip_shredded_events = false,
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

    it "refuses to rebuild across a hole left by an erasure" do
      store, aggregate_id = stream_with_one_key_destroyed

      expect_raises(ES::Exception::KeyDestroyed) do
        SecretAggregate.new(aggregate_id, store, test_event_handlers).hydrate
      end
    end

    it "rebuilds from the surviving events when the hole is opted into" do
      store, aggregate_id = stream_with_one_key_destroyed

      aggregate = SecretAggregate.new(aggregate_id, store, test_event_handlers, skip_shredded_events: true)
      aggregate.hydrate

      aggregate.state.secrets.should eq(["still readable"])
    end

    it "keeps the version moving across the hole, so later events stay in order" do
      store, aggregate_id = stream_with_one_key_destroyed

      aggregate = SecretAggregate.new(aggregate_id, store, test_event_handlers, skip_shredded_events: true)
      aggregate.hydrate

      aggregate.state.version.should eq(2)
    end
  end
end

describe ES::Projection do
  describe "#replay over an encrypted stream" do
    it "skips erased events and completes, so read models stay rebuildable" do
      SecretProjection.seen = [] of String
      store, _ = stream_with_one_key_destroyed

      SecretProjection.new(
        event_handlers: test_event_handlers,
        event_store: store,
        projection_database: DBMock.open,
      ).replay(truncate: true)

      SecretProjection.seen.should eq(["still readable"])
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

    it "refuses a shredded event, which has no body to build from" do
      store, aggregate_id = stream_with_one_key_destroyed

      expect_raises(ES::Exception::KeyDestroyed) do
        test_event_handlers.materialize(store.fetch_events(aggregate_id).first)
      end
    end
  end
end
