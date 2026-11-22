require "../../spec_helper"
require "pg"

# `EventStore#append(events, condition)` appends a batch atomically, on the
# condition that nothing matching a query was appended after a position. The
# same scenarios run against every adapter; the Postgres ones, including the
# concurrency races, need a live database and only run when ES_TEST_DATABASE_URL
# is set, e.g.
#   ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec

class AppendCourseDefined < ES::Event
  include ::ES::EventDSL

  define_event "course", "append_test.course_defined" do
    attribute :course_id, UUID
    attribute :capacity, Int32
    tag :course_id
  end
end

class AppendStudentSubscribed < ES::Event
  include ::ES::EventDSL

  define_event "course", "append_test.student_subscribed" do
    attribute :course_id, UUID
    attribute :student_id, UUID
    tag :course_id
    tag :student_id
  end
end

class AppendAccountRegistered < ES::Event
  include ::ES::EventDSL

  define_event "account", "append_test.account_registered" do
    attribute :student_email, String
    tag :student_email, hashed: true
  end
end

private def defined(course_id : UUID, capacity = 1)
  AppendCourseDefined.new(actor_id: nil, command_handler: "test", course_id: course_id, capacity: capacity)
end

private def joined(course_id : UUID, student_id = UUID.v7)
  AppendStudentSubscribed.new(actor_id: nil, command_handler: "test", course_id: course_id, student_id: student_id)
end

private def registered(email : String)
  AppendAccountRegistered.new(actor_id: nil, command_handler: "test", student_email: email)
end

private def course_query(course_id : UUID) : ES::Query
  ES::Query.new(ES::QueryItem.new(AppendCourseDefined, AppendStudentSubscribed, tags: {course_id: course_id}))
end

private def append_hasher : ES::TagHasher
  ES::TagHasher.new(ES::ApplicationEncryptionKeyManager.new(Bytes.new(32, 9_u8)))
end

# Append scenarios shared by every adapter. `build` returns an empty store wired
# to the given tag hasher.
private def append_scenarios(&build : ES::TagHasher? -> ES::EventStore)
  it "appends a batch in order and returns the last position" do
    store = build.call(append_hasher)
    course = UUID.v7
    events = [defined(course), joined(course), joined(course)]

    position = store.append(events)

    found = store.read(course_query(course))
    found.map(&.header["event_id"].as_s).should eq(events.map(&.header.event_id.to_s))
    found.last.position.should eq(position)
  end

  it "appends when nothing matches the condition" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(UUID.v7))

    store.append([defined(course)], ES::AppendCondition.new(course_query(course)))

    store.read(course_query(course)).size.should eq(1)
  end

  it "fails without an after position when any matching event exists, appending nothing" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))

    expect_raises(ES::Exception::Conflict, /after position none/) do
      store.append([joined(course), joined(course)], ES::AppendCondition.new(course_query(course)))
    end

    store.read(ES::Query.all).size.should eq(1)
  end

  it "appends after the position a decision saw, and fails once a matching event follows it" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    seen = store.read(course_query(course)).last.position
    condition = ES::AppendCondition.new(course_query(course), after: seen)

    # Another decision on the same course gets in first
    store.append([joined(course)], condition)

    expect_raises(ES::Exception::Conflict) { store.append([joined(course)], condition) }
    store.read(course_query(course)).size.should eq(2)
  end

  it "ignores events appended after the position that do not match" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    condition = ES::AppendCondition.new(course_query(course), after: store.read(course_query(course)).last.position)

    store.append(defined(UUID.v7))
    store.append(joined(UUID.v7))
    store.append(DummyEvent.new)

    store.append([joined(course)], condition)
    store.read(course_query(course)).size.should eq(2)
  end

  it "checks items without tags by type, and an empty item against every event" do
    store = build.call(append_hasher)
    store.append(defined(UUID.v7))

    expect_raises(ES::Exception::Conflict) do
      store.append([DummyEvent.new], ES::AppendCondition.new(ES::Query.new(ES::QueryItem.new(AppendCourseDefined))))
    end
    store.append([DummyEvent.new], ES::AppendCondition.new(ES::Query.new(ES::QueryItem.new(AppendStudentSubscribed))))

    expect_raises(ES::Exception::Conflict) do
      store.append([DummyEvent.new], ES::AppendCondition.new(ES::Query.all))
    end
  end

  it "checks a hashed tag without naming its value in the conflict" do
    store = build.call(append_hasher)
    store.append(registered("jane@example.com"))
    unique_email = ES::AppendCondition.new(ES::Query.new(ES::QueryItem.new(AppendAccountRegistered, tags: {student_email: "jane@example.com"})))

    error = expect_raises(ES::Exception::Conflict) { store.append([registered("jane@example.com")], unique_email) }

    error.message.to_s.should_not contain("jane")
    store.append([registered("john@example.com")], ES::AppendCondition.new(ES::Query.new(ES::QueryItem.new(AppendAccountRegistered, tags: {student_email: "john@example.com"}))))
  end

  it "appends nothing when one event of a batch cannot be encoded" do
    store = build.call(nil)

    expect_raises(ES::Exception::InvalidState, /no tag hasher/) do
      store.append([defined(UUID.v7), registered("jane@example.com")])
    end

    store.read(ES::Query.all).should be_empty
  end

  it "takes arrays of one event type and of several, without casting" do
    store = build.call(append_hasher)
    course = UUID.v7

    store.append([defined(course)])
    store.append([joined(course), joined(course)], ES::AppendCondition.new(course_query(course), after: store.read(course_query(course)).last.position))
    store.append([defined(UUID.v7), joined(course)])

    store.read(course_query(course)).size.should eq(4)
  end

  it "appends a batch carrying more distinct tags than are locked one by one" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    seen = store.read(course_query(course)).last.position
    batch = Array.new(ES::EventStoreAdapters::Postgres::MAX_LOCK_KEYS + 10) { joined(course) }

    store.append(batch, ES::AppendCondition.new(course_query(course), after: seen))

    store.read(course_query(course)).size.should eq(batch.size + 1)
    expect_raises(ES::Exception::Conflict) { store.append([joined(course)], ES::AppendCondition.new(course_query(course), after: seen)) }
  end

  it "refuses an empty batch" do
    store = build.call(append_hasher)

    expect_raises(ES::Exception::InvalidState, /empty/) { store.append([] of ES::Event) }
  end
end

describe ES::AppendCondition do
  it "refuses a negative after position" do
    expect_raises(ES::Exception::InvalidState, /after/) { ES::AppendCondition.new(ES::Query.all, after: -1_i64) }
  end
end

describe "ES::EventStoreAdapters::InMemory#append with a condition" do
  append_scenarios { |hasher| ES::EventStoreAdapters::InMemory.new(tag_hasher: hasher).as(ES::EventStore) }

  it "refuses an event id that is already stored or repeated in the batch, as Postgres does" do
    store = ES::EventStoreAdapters::InMemory.new
    event = DummyEvent.new
    store.append(event)

    expect_raises(ES::Exception::Conflict, /already stored or repeated/) { store.append(event) }
    other = DummyEvent.new
    expect_raises(ES::Exception::Conflict, /already stored or repeated/) { store.append([other, other]) }
    store.read(ES::Query.all).size.should eq(1)
  end
end

module PostgresAppendConditionSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.db : DB::Database
    @@db ||= begin
      url = URL || raise "ES_TEST_DATABASE_URL is not set"
      # Open every racer's connection up front. Connecting takes long enough that
      # racers opening their own would run one after another, not at once.
      DB.open(url + (url.includes?('?') ? "&" : "?") + "initial_pool_size=16&max_idle_pool_size=16")
    end
  end

  # A store on a freshly created event store schema
  def self.fresh_store(hasher : ES::TagHasher?) : ES::EventStoreAdapters::Postgres
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    store = ES::EventStoreAdapters::Postgres.new(db, nil, hasher)
    store.setup
    store
  end

  # Lets `count` deciders read, then releases them to append all at once, so
  # every decision is taken on the same stale read. Returns how many appends
  # succeeded and how many hit a conflict.
  def self.race(count : Int32, &decide : -> Nil) : {Int32, Int32}
    go = Channel(Nil).new
    results = Channel(Symbol).new(count)

    count.times do
      spawn do
        go.receive
        begin
          decide.call
          results.send(:appended)
        rescue ES::Exception::Conflict
          results.send(:conflict)
        rescue ex
          results.send(:error)
          raise ex
        end
      end
    end

    count.times { go.send(nil) }
    outcomes = Array.new(count) { results.receive }
    outcomes.should_not contain(:error)
    {outcomes.count(:appended), outcomes.count(:conflict)}
  end
end

describe "ES::EventStoreAdapters::Postgres#append with a condition" do
  if PostgresAppendConditionSpec::URL
    append_scenarios { |hasher| PostgresAppendConditionSpec.fresh_store(hasher).as(ES::EventStore) }

    it "lets exactly one of many concurrent decisions on a full course through" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7
      store.append(defined(course, capacity: 1))
      seen = store.read(course_query(course)).last.position

      appended, conflicts = PostgresAppendConditionSpec.race(8) do
        store.append([joined(course)], ES::AppendCondition.new(course_query(course), after: seen))
        nil
      end

      appended.should eq(1)
      conflicts.should eq(7)
      store.read(ES::Query.new(ES::QueryItem.new(AppendStudentSubscribed, tags: {course_id: course}))).size.should eq(1)
    end

    it "lets exactly one of many concurrent registrations of the same hashed email through" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      query = ES::Query.new(ES::QueryItem.new(AppendAccountRegistered, tags: {student_email: "jane@example.com"}))

      appended, conflicts = PostgresAppendConditionSpec.race(8) do
        store.append([registered("jane@example.com")], ES::AppendCondition.new(query))
        nil
      end

      appended.should eq(1)
      conflicts.should eq(7)
    end

    it "does not serialize concurrent decisions on different boundaries against each other" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      courses = Array.new(8) { UUID.v7 }
      courses.each { |course| store.append(defined(course)) }
      index = Atomic(Int32).new(0)

      appended, conflicts = PostgresAppendConditionSpec.race(8) do
        course = courses[index.add(1)]
        store.append([joined(course)], ES::AppendCondition.new(course_query(course), after: store.read(course_query(course)).last.position))
        nil
      end

      appended.should eq(8)
      conflicts.should eq(0)
    end

    # The interleaving a lock-free read gets wrong: a matching event with a lower
    # position commits after a higher one, between the read and the check, so
    # the check — looking past the highest position read — never sees it.
    it "does not let a read miss a matching event that commits late with a lower position" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7
      store.append(defined(course))
      db = PostgresAppendConditionSpec.db
      late = joined(course)
      lock_names = ["*", "handle:#{late.header.event_handle}"] + late.tags.map { |tag| "tag:#{tag.plain}" }

      # Writer one takes its locks as `append` does and inserts, but does not commit yet
      writer = db.checkout
      writer.exec "BEGIN"
      lock_names.each { |name| writer.exec %(SELECT pg_advisory_xact_lock_shared($1, $2)), ES::EventStoreAdapters::Postgres::LOCK_NAMESPACE, ES::EventStoreAdapters::Postgres.lock_key(name) }
      writer.exec %(INSERT INTO "eventstore"."events" (header, body) VALUES ($1, $2)), late.header.with_tags(late.tags.map(&.plain)).to_json, late.body.to_json

      # Writer two gets a higher position and commits first
      store.append(joined(course))

      read = Channel(Array(ES::EventStore::Event)).new(1)
      spawn { read.send(store.read(course_query(course))) }
      sleep 200.milliseconds
      writer.exec "COMMIT"
      writer.release
      seen = read.receive

      # The read must have waited for writer one rather than come back without it
      seen.map(&.header["event_id"].as_s).should contain(late.header.event_id.to_s)
      seen.size.should eq(3)
    end

    it "does not let a plain append slip past a concurrent check" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7
      store.append(defined(course))
      seen = store.read(course_query(course)).last.position
      toggle = Atomic(Int32).new(0)

      # Half the racers append unconditionally, half on the condition. Whatever
      # the interleaving, a conditional append may only succeed if no plain
      # append to the course committed before its check.
      PostgresAppendConditionSpec.race(8) do
        if toggle.add(1).even?
          store.append(joined(course))
        else
          store.append([joined(course)], ES::AppendCondition.new(course_query(course), after: seen))
        end
        nil
      end

      events = store.read(course_query(course), after: seen)
      events.size.should be >= 4
      # The check passes only for the first event of the course after `seen`,
      # so at most one conditional append can be among the events.
      (events.size - 4).should be <= 1
    end
  else
    pending "runs the append scenarios and races against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
