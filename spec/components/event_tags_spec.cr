require "../spec_helper"

class TaggedTestEvent < ES::Event
  include ::ES::EventDSL

  define_event "course", "test.student_subscribed" do
    attribute :course_id, UUID
    attribute :student_email, String
    tag :course_id, UUID
    tag :student_email, String, hashed: true
    tag :referrer, String?
  end
end

class PlainTaggedTestEvent < ES::Event
  include ::ES::EventDSL

  define_event "course", "test.course_opened" do
    attribute :course_id, UUID
    tag :course_id, UUID, hashed: false
  end
end

# A tag that names nothing in the body, and one sharing a name with an
# attribute while holding a different value
class IndependentTagsTestEvent < ES::Event
  include ::ES::EventDSL

  define_event "transfer", "test.funds_reserved" do
    attribute :account_id, UUID
    tag :account_id, UUID
    tag :transfer_id, UUID
  end
end

# An event bringing tags to encode on top of stored ones, which no generated
# constructor produces
class BothTagsTestEvent < TaggedTestEvent
  def tags : Array(ES::Tag)
    [ES::Tag.new(:course_id, "y")]
  end
end

private def tagged_event(course_id = UUID.v7, email = "jane@example.com", referrer : String? = nil)
  TaggedTestEvent.new(
    actor_id: nil, command_handler: "test", course_id: course_id, student_email: email,
    tags: {course_id: course_id, student_email: email, referrer: referrer}
  )
end

describe ES::Tag do
  it "renders an unhashed tag as key:value" do
    ES::Tag.new(:course_id, "c1").plain.should eq("course_id:c1")
  end

  it "keeps the value of a hashed tag out of to_s and inspect" do
    tag = ES::Tag.new(:student_email, "jane@example.com", hashed: true)

    tag.to_s.should eq("student_email:[hashed]")
    tag.inspect.should_not contain("jane")
  end

  it "has no plaintext stored form when hashed" do
    expect_raises(ES::Exception::InvalidState, /hashed/) do
      ES::Tag.new(:student_email, "jane@example.com", hashed: true).plain
    end
  end

  it "rejects keys that would make the stored form ambiguous" do
    expect_raises(ES::Exception::InvalidState) { ES::Tag.new("", "x") }
    expect_raises(ES::Exception::InvalidState) { ES::Tag.new("a:b", "x") }
    expect_raises(ES::Exception::InvalidState) { ES::Tag.new("a\0b", "x") }
  end
end

describe ES::ApplicationEncryptionKeyManager do
  it "derives a different key per label" do
    manager = test_application_key

    manager.derive_key("a").should_not eq(manager.derive_key("b"))
    manager.derive_key("a").should eq(manager.derive_key("a"))
  end

  it "never derives one of the key-wrapping subkeys" do
    key = ES::PayloadCipher.random_key
    manager = ES::ApplicationEncryptionKeyManager.new(key)

    {ES::PayloadCipher::ENCRYPTION_SUBKEY, ES::PayloadCipher::MAC_SUBKEY}.each do |label|
      manager.derive_key(label).should_not eq(OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, label))
    end
  end

  it "keeps the key out of inspect and to_s" do
    key = ES::PayloadCipher.random_key
    manager = ES::ApplicationEncryptionKeyManager.new(key)

    manager.inspect.should_not contain(key.to_s)
    manager.inspect.should_not contain(key[0].to_s + ", " + key[1].to_s)
    manager.to_s.should contain(manager.key_id)
  end
end

describe ES::TagHasher do
  it "stores a hashed tag as key and truncated hex digest" do
    stored = ES::TagHasher.new(test_application_key).encode(ES::Tag.new(:student_email, "jane@example.com", hashed: true))

    stored.should match(/\Astudent_email:[0-9a-f]{32}\z/)
    stored.should_not contain("jane")
  end

  it "is deterministic under the same application key" do
    key = test_application_key
    tag = ES::Tag.new(:student_email, "jane@example.com", hashed: true)

    ES::TagHasher.new(key).encode(tag).should eq(ES::TagHasher.new(key).encode(tag))
  end

  it "is not a plain hash of the value" do
    stored = ES::TagHasher.new(test_application_key).encode(ES::Tag.new(:student_email, "jane@example.com", hashed: true))

    stored.should_not contain(Digest::SHA256.hexdigest("jane@example.com")[0, 32])
    stored.should_not contain(Digest::SHA256.hexdigest("student_email\0jane@example.com")[0, 32])
  end

  it "depends on the application key" do
    tag = ES::Tag.new(:student_email, "jane@example.com", hashed: true)

    ES::TagHasher.new(test_application_key).encode(tag).should_not eq(ES::TagHasher.new(test_application_key).encode(tag))
  end

  it "cannot link the same value under two keys" do
    hasher = ES::TagHasher.new(test_application_key)
    email = hasher.encode(ES::Tag.new(:email, "jane", hashed: true)).split(':').last
    username = hasher.encode(ES::Tag.new(:username, "jane", hashed: true)).split(':').last

    email.should_not eq(username)
  end

  it "keeps the derived key out of inspect and to_s" do
    hasher = ES::TagHasher.new(test_application_key)

    hasher.inspect.should eq("#<ES::TagHasher>")
    hasher.to_s.should eq("#<ES::TagHasher>")
  end

  it "passes an unhashed tag through unchanged" do
    ES::TagHasher.new(test_application_key).encode(ES::Tag.new(:course_id, "c1")).should eq("course_id:c1")
  end
end

describe "ES::EventDSL tags" do
  it "exposes the declared tags with their hashing" do
    TaggedTestEvent.tag_definitions.should eq([{"course_id", false}, {"student_email", true}, {"referrer", false}])
    PlainTaggedTestEvent.tag_definitions.should eq([{"course_id", false}])
  end

  it "declares no tags on an event without any" do
    EncryptedEvent.tag_definitions.should be_empty
    EncryptedEvent.new(actor_id: nil, command_handler: "test", encryption_key_id: UUID.v7, secret: "s").tags.should be_empty
    DummyEvent.new.tags.should be_empty
  end

  it "takes tag values from the tags argument" do
    course_id = UUID.v7
    tags = tagged_event(course_id, referrer: "newsletter").tags

    tags.map(&.key).should eq(["course_id", "student_email", "referrer"])
    tags.map(&.value).should eq([course_id.to_s, "jane@example.com", "newsletter"])
    tags.map(&.hashed?).should eq([false, true, false])
  end

  it "keeps tags independent of the body" do
    account, other_account, transfer = UUID.v7, UUID.v7, UUID.v7
    event = IndependentTagsTestEvent.new(
      actor_id: nil, command_handler: "test", account_id: account,
      tags: {account_id: other_account, transfer_id: transfer}
    )

    event.body.as(IndependentTagsTestEvent::Body).account_id.should eq(account)
    event.tags.map(&.value).should eq([other_account.to_s, transfer.to_s])
    event.body.to_json.should_not contain(transfer.to_s)
  end

  it "carries no tag for a nil value" do
    tagged_event(referrer: nil).tags.map(&.key).should eq(["course_id", "student_email"])
  end

  it "leaves the header tags empty until the event is stored" do
    tagged_event.header.tags.should be_empty
  end
end

describe "Event store tag encoding" do
  it "stores unhashed and hashed tags on the header" do
    hasher = ES::TagHasher.new(test_application_key)
    store = ES::EventStoreAdapters::InMemory.new(tag_hasher: hasher)
    course_id = UUID.v7
    event = tagged_event(course_id)

    store.append(event)

    stored = store.fetch_event(event.header.event_id)
    stored.header["tags"].as_a.map(&.as_s).should eq([
      "course_id:#{course_id}",
      hasher.encode(ES::Tag.new(:student_email, "jane@example.com", hashed: true)),
    ])
    stored.header.to_json.should_not contain("jane")
  end

  it "reads the stored tags back onto the header" do
    store = ES::EventStoreAdapters::InMemory.new(tag_hasher: ES::TagHasher.new(test_application_key))
    event = tagged_event
    store.append(event)

    header = ES::Event::Header.from_json(store.fetch_event(event.header.event_id).header.to_json)

    header.tags.size.should eq(2)
    header.tags.first.should eq("course_id:#{event.body.as(TaggedTestEvent::Body).course_id}")
  end

  it "stores unhashed tags without a tag hasher" do
    store = ES::EventStoreAdapters::InMemory.new(tag_hasher: nil)
    course_id = UUID.v7
    event = PlainTaggedTestEvent.new(actor_id: nil, command_handler: "test", course_id: course_id, tags: {course_id: course_id})

    store.append(event)

    store.fetch_event(event.header.event_id).header["tags"].as_a.map(&.as_s).should eq(["course_id:#{course_id}"])
  end

  it "refuses a hashed tag without a tag hasher and stores nothing" do
    store = ES::EventStoreAdapters::InMemory.new(tag_hasher: nil)
    event = tagged_event

    expect_raises(ES::Exception::InvalidState, /no tag hasher/) { store.append(event) }
    store.last_event_id.should be_nil
  end

  it "takes the tag hasher from the configuration by default" do
    hasher = ES::TagHasher.new(test_application_key)
    ES::Config.tag_hasher = hasher
    store = ES::EventStoreAdapters::InMemory.new
    event = tagged_event

    store.append(event)

    store.fetch_event(event.header.event_id).header["tags"].as_a.size.should eq(2)
  end

  it "writes an untagged header without a tags field" do
    store = ES::EventStoreAdapters::InMemory.new
    event = DummyEvent.new
    store.append(event)

    event.header.to_json.should_not contain("tags")
    store.fetch_event(event.header.event_id).header["tags"]?.should be_nil
  end

  it "queues the stored header, tags included" do
    queue = ES::QueueAdapters::InMemory.new("test_queue")
    store = ES::EventStoreAdapters::InMemory.new(queue, tag_hasher: ES::TagHasher.new(test_application_key))
    event = tagged_event
    store.append(event)

    # `read` is protected, and the header is all this spec is about
    entry = queue.@queue.values.first
    entry.header.tags.should eq(ES::Event::Header.from_json(store.fetch_event(event.header.event_id).header.to_json).tags)
    entry.header.tags.size.should eq(2)
    entry.header.to_json.should_not contain("jane")
  end

  it "keeps the stored tags of an event read back and appended again" do
    hasher = ES::TagHasher.new(test_application_key)
    source = ES::EventStoreAdapters::InMemory.new(tag_hasher: hasher)
    event = tagged_event
    source.append(event)
    stored = source.fetch_event(event.header.event_id)
    read_back = TaggedTestEvent.new(ES::Event::Header.from_json(stored.header.to_json), stored.body)

    target = ES::EventStoreAdapters::InMemory.new(tag_hasher: nil)
    target.append(read_back)

    target.fetch_event(event.header.event_id).header["tags"].should eq(stored.header["tags"])
  end

  it "refuses a stored tag the event does not declare, or plaintext under a hashed key" do
    store = ES::EventStoreAdapters::InMemory.new(tag_hasher: ES::TagHasher.new(test_application_key))
    body = JSON.parse(%({"comment": "", "course_id": "#{UUID.v7}", "student_email": "jane@example.com"}))
    forged = ->(tags : Array(String)) do
      header = JSON.parse(ES::Event::Header.new(actor_id: nil, aggregate_id: UUID.v7, aggregate_version: 1, event_handle: "test.student_subscribed").to_json).as_h
      header["tags"] = JSON::Any.new(tags.map { |tag| JSON::Any.new(tag) })
      TaggedTestEvent.new(ES::Event::Header.from_json(header.to_json), body)
    end

    error = expect_raises(ES::Exception::InvalidState, /declared hashed but holds no digest/) { store.append(forged.call(["student_email:jane@example.com"])) }
    error.message.to_s.should_not contain("jane")
    expect_raises(ES::Exception::InvalidState, /does not declare/) { store.append(forged.call(["victim_course:#{UUID.v7}"])) }
    expect_raises(ES::Exception::InvalidState, /does not declare/) { store.append(DummyEvent.new(ES::Event::Header.from_json(forged.call(["course_id:x"]).header.to_json), JSON.parse(%({"comment": ""})))) }
    store.read(ES::Query.all).should be_empty
  end

  it "refuses an event carrying both tags to encode and stored tags" do
    store = ES::EventStoreAdapters::InMemory.new(tag_hasher: ES::TagHasher.new(test_application_key))
    source = tagged_event
    event = BothTagsTestEvent.new(source.header.with_tags(["course_id:x"]), JSON.parse(source.body.to_json))

    expect_raises(ES::Exception::InvalidState, /both tags to encode and stored tags/) { store.append(event) }
  end

  it "reads a header written before tags existed" do
    json = ES::Event::Header.new(actor_id: nil, aggregate_id: UUID.v7, aggregate_version: 1, event_handle: "dummy").to_json
    legacy = JSON.parse(json).as_h.reject("tags").to_json

    ES::Event::Header.from_json(legacy).tags.should be_empty
  end
end
