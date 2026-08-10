require "../spec_helper"

# Reaches the shared decode path of a store that was never given encryption,
# which no public method can otherwise be pointed at an envelope.
class UnconfiguredStore < ES::EventStoreAdapters::InMemory
  def decode!(header : JSON::Any, body : JSON::Any) : ES::EventStore::Event
    decode(header, body)
  end
end

# How an encrypted body behaves once it goes through an event store: what lands on
# disk, what comes back out, and what an erasure leaves behind.
describe "encrypted events in an event store" do
  it "stores an envelope rather than the plaintext body" do
    encryption = test_encryption
    store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
    event = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler",
      encryption_key_id: encryption.create_key, secret: "iban-of-a-real-person"
    )

    store.append(event)

    # Reaching past the adapter on purpose: this asserts what is actually at rest,
    # which is the whole point of the feature.
    raw = store.@events[event.header.event_id]
    ES::Encryption.envelope?(raw.body).should be_true
    raw.body.to_json.includes?("iban-of-a-real-person").should be_false
  end

  it "hands the plaintext back on read" do
    encryption = test_encryption
    store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
    event = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler",
      encryption_key_id: encryption.create_key, secret: "recovered"
    )

    store.append(event)
    stored = store.fetch_event(event.header.event_id)

    stored.shredded?.should be_false
    stored.body["secret"].as_s.should eq("recovered")
  end

  it "returns the same plaintext through every read path" do
    encryption = test_encryption
    store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
    event = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler",
      encryption_key_id: encryption.create_key, secret: "recovered"
    )
    store.append(event)

    store.fetch_events(event.header.aggregate_id).first.body["secret"].as_s.should eq("recovered")

    streamed = [] of String
    store.each_event { |e| streamed << e.body["secret"].as_s }
    streamed.should eq(["recovered"])
  end

  it "leaves an event without a key in plaintext" do
    store = ES::EventStoreAdapters::InMemory.new(encryption: test_encryption)
    event = PlainEvent.new(actor_id: nil, command_handler: "handler", secret: "not a secret")

    store.append(event)

    store.@events[event.header.event_id].body["secret"].as_s.should eq("not a secret")
  end

  it "refuses to store a declared-encrypted event when no encryption is configured" do
    store = ES::EventStoreAdapters::InMemory.new
    event = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler",
      encryption_key_id: UUID.v7, secret: "secret"
    )

    expect_raises(ES::Exception::InvalidState) do
      store.append(event)
    end
  end

  it "refuses to read an encrypted body when no encryption is configured" do
    encryption = test_encryption
    written = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
    event = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler",
      encryption_key_id: encryption.create_key, secret: "secret"
    )
    written.append(event)
    stored = written.@events[event.header.event_id]

    expect_raises(ES::Exception::DependencyUnavailable) do
      UnconfiguredStore.new.decode!(stored.header, stored.body)
    end
  end

  it "behaves exactly as before when no encryption is configured at all" do
    store = ES::EventStoreAdapters::InMemory.new
    event = PlainEvent.new(actor_id: nil, command_handler: "handler", secret: "plain")

    store.append(event)

    store.fetch_event(event.header.event_id).body["secret"].as_s.should eq("plain")
    store.fetch_event(event.header.event_id).shredded?.should be_false
  end

  describe "after the key is destroyed" do
    it "reports the event as shredded and returns nothing" do
      encryption = test_encryption
      store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
      key_id = encryption.create_key
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "to be erased"
      )
      store.append(event)

      encryption.destroy_key(key_id)
      stored = store.fetch_event(event.header.event_id)

      stored.shredded?.should be_true
      stored.body.as_h.should be_empty
    end

    it "still exposes the header, so the stream keeps its shape" do
      encryption = test_encryption
      store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
      key_id = encryption.create_key
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "to be erased"
      )
      store.append(event)
      encryption.destroy_key(key_id)

      stored = store.fetch_event(event.header.event_id)

      stored.header["aggregate_version"].as_i.should eq(1)
      stored.header["event_handle"].as_s.should eq("encrypted_dummy")
    end
  end

  describe "#encryption_key_ids" do
    it "finds every key used across a stream, which is what an erasure needs" do
      encryption = test_encryption
      store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
      aggregate_id = UUID.v7

      first_key = encryption.create_key
      second_key = encryption.create_key

      store.append(EncryptedEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 1, encryption_key_id: first_key, secret: "one"
      ))
      store.append(EncryptedEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 2, encryption_key_id: second_key, secret: "two"
      ))
      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 3, secret: "three"
      ))

      store.encryption_key_ids(aggregate_id).sort.should eq([first_key, second_key].sort)
    end

    it "returns nothing for a stream that uses no keys" do
      store = ES::EventStoreAdapters::InMemory.new(encryption: test_encryption)
      event = PlainEvent.new(actor_id: nil, command_handler: "handler", secret: "plain")
      store.append(event)

      store.encryption_key_ids(event.header.aggregate_id).should be_empty
    end

    it "ignores other aggregates" do
      encryption = test_encryption
      store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )
      store.append(event)

      store.encryption_key_ids(UUID.v7).should be_empty
    end
  end

  it "erases one key's events and leaves the rest of the stream readable" do
    encryption = test_encryption
    store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
    aggregate_id = UUID.v7

    erased_key = encryption.create_key
    kept_key = encryption.create_key

    erased = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
      aggregate_version: 1, encryption_key_id: erased_key, secret: "personal data"
    )
    kept = EncryptedEvent.new(
      actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
      aggregate_version: 2, encryption_key_id: kept_key, secret: "someone else's data"
    )
    store.append(erased)
    store.append(kept)

    encryption.destroy_key(erased_key)
    events = store.fetch_events(aggregate_id)

    events[0].shredded?.should be_true
    events[1].shredded?.should be_false
    events[1].body["secret"].as_s.should eq("someone else's data")
  end
end
