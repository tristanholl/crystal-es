require "../../spec_helper"
require "pg"
require "log/spec"

# `EventStore#read` selects events by type and tag. The same scenarios run
# against every adapter; the Postgres ones need a live database and only run
# when ES_TEST_DATABASE_URL is set, e.g.
#   ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec

class QueryCourseDefined < ES::Event
  include ::ES::EventDSL

  define_event "course", "query_test.course_defined" do
    attribute :course_id, UUID
    attribute :capacity, Int32
    tag :course_id, UUID
  end
end

class QueryStudentSubscribed < ES::Event
  include ::ES::EventDSL

  define_event "course", "query_test.student_subscribed" do
    attribute :course_id, UUID
    attribute :student_id, UUID
    attribute :student_email, String
    tag :course_id, UUID
    tag :student_id, UUID
    tag :student_email, String, hashed: true
  end
end

class QueryProfileRecorded < ES::Event
  include ::ES::EventDSL

  define_event "course", "query_test.profile_recorded", encrypted: true do
    attribute :course_id, UUID
    attribute :student_email, String
    tag :course_id, UUID
    tag :student_email, String, hashed: true
  end
end

private def course_defined(course_id : UUID, capacity = 10)
  QueryCourseDefined.new(actor_id: nil, command_handler: "test", course_id: course_id, capacity: capacity, tags: {course_id: course_id})
end

private def subscribed(course_id : UUID, student_id = UUID.v7, email = "jane@example.com")
  QueryStudentSubscribed.new(
    actor_id: nil, command_handler: "test", course_id: course_id, student_id: student_id, student_email: email,
    tags: {course_id: course_id, student_id: student_id, student_email: email}
  )
end

private def event_ids(events : Array(ES::EventStore::Event)) : Array(UUID)
  events.map { |event| UUID.new(event.header["event_id"].as_s) }
end

private def query_hasher : ES::TagHasher
  ES::TagHasher.new(ES::ApplicationEncryptionKeyManager.new(Bytes.new(32, 7_u8)))
end

# Read scenarios shared by every adapter. `build` returns an empty store wired
# to the given tag hasher and encryption.
private def read_scenarios(&build : ES::TagHasher?, ES::EncryptionKeyManager? -> ES::EventStore)
  it "matches events carrying all tags of an item" do
    store = build.call(query_hasher, nil)
    course, other_course, student = UUID.v7, UUID.v7, UUID.v7
    hit = subscribed(course, student)
    [hit, subscribed(course), subscribed(other_course, student)].each { |event| store.append(event) }

    found = store.read(ES::Query.new(ES::QueryItem.new(tags: {course_id: course, student_id: student})))

    event_ids(found).should eq([hit.header.event_id])
  end

  it "matches any of several items, in append order" do
    store = build.call(query_hasher, nil)
    course, other_course = UUID.v7, UUID.v7
    defined = course_defined(course)
    joined = subscribed(course)
    [defined, course_defined(other_course), joined, subscribed(other_course)].each { |event| store.append(event) }

    found = store.read(ES::Query.new(
      ES::QueryItem.new(QueryCourseDefined, tags: {course_id: course}),
      ES::QueryItem.new(QueryStudentSubscribed, tags: {course_id: course}),
    ))

    event_ids(found).should eq([defined.header.event_id, joined.header.event_id])
  end

  it "restricts an item to its types" do
    store = build.call(query_hasher, nil)
    course = UUID.v7
    defined = course_defined(course)
    [defined, subscribed(course)].each { |event| store.append(event) }

    event_ids(store.read(ES::Query.new(ES::QueryItem.new(QueryCourseDefined, tags: {course_id: course})))).should eq([defined.header.event_id])
    event_ids(store.read(ES::Query.new(ES::QueryItem.new(QueryCourseDefined)))).should eq([defined.header.event_id])
  end

  it "finds an event by a hashed tag without storing its value" do
    store = build.call(query_hasher, nil)
    jane = subscribed(UUID.v7, email: "jane@example.com")
    [jane, subscribed(UUID.v7, email: "john@example.com")].each { |event| store.append(event) }

    found = store.read(ES::Query.new(ES::QueryItem.new(tags: {student_email: "jane@example.com"})))

    event_ids(found).should eq([jane.header.event_id])
    found.first.header["tags"].to_json.should_not contain("jane")
  end

  it "returns every event, tagged or not, for Query.all" do
    store = build.call(query_hasher, nil)
    events = [DummyEvent.new, course_defined(UUID.v7), DummyEvent.new]
    events.each { |event| store.append(event) }

    event_ids(store.read(ES::Query.all)).should eq(events.map(&.header.event_id))
  end

  it "returns increasing positions and honours after and limit" do
    store = build.call(query_hasher, nil)
    course = UUID.v7
    events = Array.new(4) { subscribed(course) }
    events.each { |event| store.append(event) }
    query = ES::Query.new(ES::QueryItem.new(tags: {course_id: course}))

    all = store.read(query)
    positions = all.compact_map(&.position)
    positions.size.should eq(4)
    positions.should eq(positions.sort)
    positions.uniq.size.should eq(4)

    event_ids(store.read(query, after: positions[1])).should eq(events[2..].map(&.header.event_id))
    event_ids(store.read(query, limit: 2)).should eq(events[0, 2].map(&.header.event_id))
    event_ids(store.read(query, after: positions[0], limit: 2)).should eq(events[1, 2].map(&.header.event_id))
    store.read(query, after: positions[3]).should be_empty
  end

  it "returns nothing when no event matches" do
    store = build.call(query_hasher, nil)
    store.append(course_defined(UUID.v7))

    store.read(ES::Query.new(ES::QueryItem.new(tags: {course_id: UUID.v7}))).should be_empty
  end

  it "refuses a query for a hashed tag without a tag hasher" do
    store = build.call(nil, nil)

    expect_raises(ES::Exception::InvalidState, /no tag hasher/) do
      store.read(ES::Query.new(ES::QueryItem.new(tags: {student_email: "jane@example.com"})))
    end
  end

  it "returns an event whose key was destroyed with its header but no body" do
    encryption = test_encryption
    store = build.call(query_hasher, encryption)
    course = UUID.v7
    key_id, kept_key_id = encryption.create_key, encryption.create_key
    erased = QueryProfileRecorded.new(actor_id: nil, command_handler: "test", encryption_key_id: key_id, course_id: course, student_email: "jane@example.com", tags: {course_id: course, student_email: "jane@example.com"})
    kept = QueryProfileRecorded.new(actor_id: nil, command_handler: "test", encryption_key_id: kept_key_id, course_id: course, student_email: "john@example.com", tags: {course_id: course, student_email: "john@example.com"})
    [erased, kept].each { |event| store.append(event) }
    encryption.destroy_key(key_id)

    found = store.read(ES::Query.new(ES::QueryItem.new(QueryProfileRecorded, tags: {course_id: course})))

    event_ids(found).should eq([erased.header.event_id, kept.header.event_id])
    found.map(&.body_erased?).should eq([true, false])
    found[0].body.raw.should be_nil
    found[0].position.should_not be_nil
    found[0].header["tags"].as_a.size.should eq(2)
    found[1].body["student_email"].as_s.should eq("john@example.com")

    # Still found by its hashed tag, though the value itself is gone with the body
    event_ids(store.read(ES::Query.new(ES::QueryItem.new(tags: {student_email: "jane@example.com"})))).should eq([erased.header.event_id])
  end

  it "refuses a limit below 1 and a negative after" do
    store = build.call(query_hasher, nil)

    expect_raises(ES::Exception::InvalidState, /limit/) { store.read(ES::Query.all, limit: 0) }
    expect_raises(ES::Exception::InvalidState, /after/) { store.read(ES::Query.all, after: -1_i64) }
  end
end

# `ES::Query.new` without items is a compile error (the typed splat needs at
# least one), so it can only be shown by its absence here.
describe ES::Query do
  it "resolves whether a tag is hashed from the event declarations" do
    item = ES::QueryItem.new(tags: {course_id: "c1", student_email: "jane@example.com", undeclared: "x"})

    item.tags.map(&.hashed?).should eq([false, true, false])
  end

  it "turns event classes into handles" do
    ES::QueryItem.new(QueryCourseDefined, QueryStudentSubscribed).types.should eq(["query_test.course_defined", "query_test.student_subscribed"])
  end

  it "refuses a nil tag value" do
    expect_raises(ES::Exception::InvalidState, /no value/) { ES::QueryItem.new(tags: {course_id: nil}) }
  end
end

describe "ES::EventStoreAdapters::InMemory#read" do
  read_scenarios { |hasher, encryption| ES::EventStoreAdapters::InMemory.new(encryption: encryption, tag_hasher: hasher).as(ES::EventStore) }

  it "refuses to materialize an event whose body was erased" do
    encryption = test_encryption
    store = ES::EventStoreAdapters::InMemory.new(encryption: encryption)
    key_id = encryption.create_key
    store.append(EncryptedEvent.new(actor_id: nil, command_handler: "test", encryption_key_id: key_id, secret: "s"))
    encryption.destroy_key(key_id)

    erased = store.read(ES::Query.all).first

    expect_raises(ES::Exception::InvalidState, /erased/) { test_event_handlers.materialize(erased) }
  end
end

module PostgresReadQuerySpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.db : DB::Database
    @@db ||= DB.open(URL || raise "ES_TEST_DATABASE_URL is not set")
  end

  # A store on a freshly created event store schema
  def self.fresh_store(hasher : ES::TagHasher?, encryption : ES::EncryptionKeyManager? = nil) : ES::EventStoreAdapters::Postgres
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    store = ES::EventStoreAdapters::Postgres.new(db, encryption, hasher)
    store.setup
    store
  end

  def self.index_exists?(name : String) : Bool
    db.query_one(%(SELECT EXISTS (SELECT FROM pg_indexes WHERE schemaname = 'eventstore' AND indexname = $1)), name, as: Bool)
  end
end

describe "ES::EventStoreAdapters::Postgres#read" do
  if PostgresReadQuerySpec::URL
    read_scenarios { |hasher, encryption| PostgresReadQuerySpec.fresh_store(hasher, encryption).as(ES::EventStore) }

    it "creates the tag and event handle indexes on a fresh store" do
      PostgresReadQuerySpec.fresh_store(nil)

      PostgresReadQuerySpec.index_exists?("events_tags_idx").should be_true
      PostgresReadQuerySpec.index_exists?("events_event_handle_idx").should be_true
    end

    it "adds the indexes to an existing store on setup" do
      store = PostgresReadQuerySpec.fresh_store(nil)
      PostgresReadQuerySpec.db.exec %(DROP INDEX "eventstore"."events_tags_idx")
      PostgresReadQuerySpec.db.exec %(DROP INDEX "eventstore"."events_event_handle_idx")

      store.setup

      PostgresReadQuerySpec.index_exists?("events_tags_idx").should be_true
      PostgresReadQuerySpec.index_exists?("events_event_handle_idx").should be_true
    end

    it "warns about an invalid index on setup" do
      store = PostgresReadQuerySpec.fresh_store(nil)
      # What a failed CREATE INDEX CONCURRENTLY leaves behind
      PostgresReadQuerySpec.db.exec %(UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'eventstore.events_tags_idx'::regclass)

      logs = Log.capture("") { store.setup }

      logs.check(:warn, /events_tags_idx' is invalid/)
    end

    it "uses the tag index for a tag query" do
      PostgresReadQuerySpec.fresh_store(nil)
      plan = ""
      PostgresReadQuerySpec.db.transaction do |tx|
        tx.connection.exec %(SET LOCAL enable_seqscan = off)
        plan = tx.connection.query_all(%(EXPLAIN SELECT id FROM "eventstore"."events" WHERE header->'tags' @> $1::jsonb), %(["course_id:x"]), as: String).join("\n")
      end

      plan.should contain("events_tags_idx")
    end
  else
    pending "runs the read scenarios against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
