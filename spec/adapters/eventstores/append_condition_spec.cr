require "../../spec_helper"
require "pg"

# Tag versions: every tagged append raises the version of each of its tags and
# stamps it into the stored header; `append(events, condition)` appends a batch
# atomically, on the condition that the tags it names are still at the
# versions it expects. The same scenarios run against every adapter; the
# Postgres ones, including the concurrency races, need a live database and only
# run when ES_TEST_DATABASE_URL is set, e.g.
#   ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec

class AppendCourseDefined < ES::Event
  include ::ES::EventDSL

  define_event "course", "append_test.course_defined" do
    attribute :course_id, UUID
    attribute :capacity, Int32
    tag :course_id, UUID
  end
end

class AppendStudentSubscribed < ES::Event
  include ::ES::EventDSL

  define_event "course", "append_test.student_subscribed" do
    attribute :course_id, UUID
    attribute :student_id, UUID
    tag :course_id, UUID
    tag :student_id, UUID
  end
end

class AppendAccountRegistered < ES::Event
  include ::ES::EventDSL

  define_event "account", "append_test.account_registered" do
    attribute :student_email, String
    tag :student_email, String, hashed: true
  end
end

private def defined(course_id : UUID, capacity = 1)
  AppendCourseDefined.new(actor_id: nil, command_handler: "test", course_id: course_id, capacity: capacity, tags: {course_id: course_id})
end

private def joined(course_id : UUID, student_id = UUID.v7)
  AppendStudentSubscribed.new(actor_id: nil, command_handler: "test", course_id: course_id, student_id: student_id, tags: {course_id: course_id, student_id: student_id})
end

private def registered(email : String)
  AppendAccountRegistered.new(actor_id: nil, command_handler: "test", student_email: email, tags: {student_email: email})
end

private def course_query(course_id : UUID) : ES::Query
  ES::Query.new(ES::QueryItem.new(AppendCourseDefined, AppendStudentSubscribed, tags: {course_id: course_id}))
end

private def append_hasher : ES::TagHasher
  ES::TagHasher.new(ES::ApplicationEncryptionKeyManager.new(Bytes.new(32, 9_u8)))
end

private def versions_of(event : ES::EventStore::Event) : Hash(String, Int64)
  ES::Event::Header.from_json(event.header.to_json).tag_versions
end

# Scenarios shared by every adapter. `build` returns an empty store wired to the
# given tag hasher.
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

  it "stamps each event with gap-free versions of its tags" do
    store = build.call(append_hasher)
    course, student = UUID.v7, UUID.v7
    store.append(defined(course))
    store.append([joined(course, student), joined(course)])

    found = store.read(course_query(course))

    found.map { |event| versions_of(event)["course_id:#{course}"] }.should eq([1, 2, 3])
    versions_of(found[1])["student_id:#{student}"].should eq(1)
  end

  it "leaves untagged events without versions" do
    store = build.call(append_hasher)
    event = DummyEvent.new
    store.append(event)

    store.fetch_event(event.header.event_id).header["tag_versions"]?.should be_nil
  end

  it "reads a decision with the versions of its tags and appends when nothing changed" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append([defined(course), joined(course)])

    decision = store.read_for_decision(course_query(course))

    decision.events.size.should eq(2)
    decision.versions.should eq({"course_id:#{course}" => 2})
    store.append([joined(course)], decision.condition)
    store.read(course_query(course)).size.should eq(3)
  end

  it "fails once anything carrying one of the decision's tags was appended, appending nothing" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    decision = store.read_for_decision(course_query(course))

    # Another decision on the same course gets in first
    store.append([joined(course)], decision.condition)

    expect_raises(ES::Exception::Conflict, /tag 'course_id' is no longer at the expected version/) do
      store.append([joined(course), joined(course)], decision.condition)
    end
    store.read(course_query(course)).size.should eq(2)
  end

  it "counts every event carrying a tag, whatever its type" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    decision = store.read_for_decision(ES::Query.new(ES::QueryItem.new(AppendStudentSubscribed, tags: {course_id: course})))

    # Not a subscription, but it carries the course tag
    store.append(defined(course))

    expect_raises(ES::Exception::Conflict) { store.append([joined(course)], decision.condition) }
  end

  it "ignores events carrying other tags" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    decision = store.read_for_decision(course_query(course))

    store.append(defined(UUID.v7))
    store.append(joined(UUID.v7))
    store.append(DummyEvent.new)

    store.append([joined(course)], decision.condition)
    store.read(course_query(course)).size.should eq(2)
  end

  it "guards a decision across several tags" do
    store = build.call(append_hasher)
    course, student = UUID.v7, UUID.v7
    store.append(defined(course))
    query = ES::Query.new(
      ES::QueryItem.new(tags: {course_id: course}),
      ES::QueryItem.new(tags: {student_id: student}),
    )
    decision = store.read_for_decision(query)
    decision.versions.should eq({"course_id:#{course}" => 1, "student_id:#{student}" => 0})

    # The student subscribes elsewhere in the meantime
    store.append(joined(UUID.v7, student))

    expect_raises(ES::Exception::Conflict, /student_id/) { store.append([joined(course, student)], decision.condition) }
  end

  it "keeps a value unique with version 0, without naming it in the conflict" do
    store = build.call(append_hasher)
    unique = ES::AppendCondition.new.expect(:student_email, "jane@example.com", version: 0)
    store.append([registered("jane@example.com")], unique)

    error = expect_raises(ES::Exception::Conflict) { store.append([registered("jane@example.com")], unique) }

    error.message.to_s.should_not contain("jane")
    store.append([registered("john@example.com")], ES::AppendCondition.new.expect(:student_email, "john@example.com", version: 0))
    store.read(ES::Query.new(ES::QueryItem.new(AppendAccountRegistered))).size.should eq(2)
  end

  it "guards a decision with the versions a projection saw on the stored events" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))

    # What a projection keeps from the last event it applied for the course
    seen = versions_of(store.read(course_query(course)).last)
    condition = seen.reduce(ES::AppendCondition.new) { |cond, (tag, version)| cond.expect_stored(tag, version) }

    store.append([joined(course)], condition)
    expect_raises(ES::Exception::Conflict) { store.append([joined(course)], condition) }
  end

  it "assigns versions itself, ignoring those on an event read back" do
    source = build.call(append_hasher)
    course = UUID.v7
    3.times { source.append(defined(course)) }
    stored = source.read(course_query(course)).last
    read_back = AppendCourseDefined.new(ES::Event::Header.from_json(stored.header.to_json), stored.body)

    target = build.call(append_hasher)
    target.append(read_back)

    versions_of(target.read(course_query(course)).last).should eq({"course_id:#{course}" => 1})
  end

  it "refuses a decision read with an item that names no tags" do
    store = build.call(append_hasher)

    expect_raises(ES::Exception::InvalidState, /needs every query item to name tags/) do
      store.read_for_decision(ES::Query.new(ES::QueryItem.new(tags: {course_id: UUID.v7}), ES::QueryItem.new(AppendCourseDefined)))
    end
    expect_raises(ES::Exception::InvalidState, /needs every query item to name tags/) { store.read_for_decision(ES::Query.all) }
  end

  it "refuses a condition expecting one tag at two versions" do
    store = build.call(append_hasher)
    course = UUID.v7
    condition = ES::AppendCondition.new.expect(:course_id, course, version: 0).expect_stored("course_id:#{course}", 1)

    expect_raises(ES::Exception::InvalidState, /two different versions/) { store.append([defined(course)], condition) }
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
    store.append([joined(course), joined(course)], store.read_for_decision(course_query(course)).condition)
    store.append([defined(UUID.v7), joined(course)])

    store.read(course_query(course)).size.should eq(4)
  end

  it "appends a batch carrying many distinct tags" do
    store = build.call(append_hasher)
    course = UUID.v7
    store.append(defined(course))
    decision = store.read_for_decision(course_query(course))
    batch = Array.new(200) { joined(course) }

    store.append(batch, decision.condition)

    store.read(course_query(course)).size.should eq(batch.size + 1)
    expect_raises(ES::Exception::Conflict) { store.append([joined(course)], decision.condition) }
  end

  it "refuses an empty batch" do
    store = build.call(append_hasher)

    expect_raises(ES::Exception::InvalidState, /empty/) { store.append([] of ES::Event) }
  end
end

describe ES::AppendCondition do
  it "refuses a negative version and a nil value" do
    expect_raises(ES::Exception::InvalidState, /must not be negative/) { ES::AppendCondition.new.expect(:course_id, UUID.v7, version: -1) }
    expect_raises(ES::Exception::InvalidState, /no value/) { ES::AppendCondition.new.expect(:course_id, nil, version: 0) }
  end

  it "refuses keys no event declares, and malformed or plaintext stored tags" do
    expect_raises(ES::Exception::InvalidState, /'emial' is not declared/) { ES::AppendCondition.new.expect(:emial, "jane@example.com", version: 0) }
    expect_raises(ES::Exception::InvalidState, /'emial' is not declared/) { ES::AppendCondition.new.expect_stored("emial:x", 0) }
    error = expect_raises(ES::Exception::InvalidState, /form '<key>:<value>'/) { ES::AppendCondition.new.expect_stored("jane@example.com", 0) }
    error.message.to_s.should_not contain("jane")
    error = expect_raises(ES::Exception::InvalidState, /holds no digest/) { ES::AppendCondition.new.expect_stored("student_email:jane@example.com", 0) }
    error.message.to_s.should_not contain("jane")

    ES::AppendCondition.new.expect_stored("student_email:#{"ab" * 16}", 1).stored_tags.size.should eq(1)
  end

  it "resolves whether a tag is hashed from the event declarations" do
    condition = ES::AppendCondition.new.expect(:student_email, "jane@example.com", version: 0).expect(:course_id, "c1", version: 2)

    condition.tags.map { |tag, _| tag.hashed? }.should eq([true, false])
    condition.empty?.should be_false
    ES::AppendCondition.new.empty?.should be_true
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

  # Releases `count` racers at once and returns how many appends succeeded and
  # how many hit a conflict
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

    it "creates the tag versions table on an existing store" do
      store = PostgresAppendConditionSpec.fresh_store(nil)
      PostgresAppendConditionSpec.db.exec %(DROP TABLE "eventstore"."tag_versions")

      store.setup

      store.append(defined(UUID.v7))
      PostgresAppendConditionSpec.db.query_one(%(SELECT count(*) FROM "eventstore"."tag_versions"), as: Int64).should eq(1)
    end

    it "lets exactly one of many decisions taken on the same state through" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7
      store.append(defined(course, capacity: 1))
      decision = store.read_for_decision(course_query(course))

      appended, conflicts = PostgresAppendConditionSpec.race(8) do
        store.append([joined(course)], decision.condition)
        nil
      end

      appended.should eq(1)
      conflicts.should eq(7)
      store.read(ES::Query.new(ES::QueryItem.new(AppendStudentSubscribed, tags: {course_id: course}))).size.should eq(1)
    end

    it "lets exactly one of many concurrent registrations of the same hashed email through" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)

      appended, conflicts = PostgresAppendConditionSpec.race(8) do
        store.append([registered("jane@example.com")], ES::AppendCondition.new.expect(:student_email, "jane@example.com", version: 0))
        nil
      end

      appended.should eq(1)
      conflicts.should eq(7)
    end

    it "does not let decisions on different boundaries conflict" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      courses = Array.new(8) { UUID.v7 }
      courses.each { |course| store.append(defined(course)) }
      index = Atomic(Int32).new(0)

      appended, conflicts = PostgresAppendConditionSpec.race(8) do
        course = courses[index.add(1)]
        store.append([joined(course)], store.read_for_decision(course_query(course)).condition)
        nil
      end

      appended.should eq(8)
      conflicts.should eq(0)
    end

    it "keeps versions gap-free and unique under concurrent appends of one tag" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7

      PostgresAppendConditionSpec.race(8) do
        store.append([joined(course), joined(course)])
        nil
      end

      versions = store.read(course_query(course)).map { |event| versions_of(event)["course_id:#{course}"] }
      versions.sort.should eq((1_i64..16_i64).to_a)
      store.read_for_decision(course_query(course)).versions["course_id:#{course}"].should eq(16)
    end

    it "does not let a plain append slip past a concurrent conditional one" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7
      store.append(defined(course))
      decision = store.read_for_decision(course_query(course))
      toggle = Atomic(Int32).new(0)

      # Half the racers append unconditionally, half on the decision. Whatever
      # the interleaving, a conditional append may only succeed if nothing else
      # carrying the course tag committed before it, so at most one does.
      appended, _ = PostgresAppendConditionSpec.race(8) do
        if toggle.add(1).even?
          store.append(joined(course))
        else
          store.append([joined(course)], decision.condition)
        end
        nil
      end

      (appended - 4).should be <= 1
      store.read(course_query(course)).size.should eq(appended + 1)
    end

    # The interleaving positions get wrong: a write still in flight while the
    # decision reads. The read neither waits for it nor sees it, and the append
    # fails once it committed, because it raised the tag's version.
    it "catches a write that was in flight while the decision read" do
      store = PostgresAppendConditionSpec.fresh_store(append_hasher)
      course = UUID.v7
      store.append(defined(course))
      db = PostgresAppendConditionSpec.db
      tag = "course_id:#{course}"

      # A writer takes the tag's row as `append` does and raises it, but does not commit yet
      writer = db.checkout
      writer.exec "BEGIN"
      writer.exec %(UPDATE "eventstore"."tag_versions" SET version = version + 1 WHERE tag = $1), tag

      read = Channel(ES::Decision).new(1)
      spawn { read.send(store.read_for_decision(course_query(course))) }
      decision = select
      when value = read.receive then value
      when timeout(2.seconds) then raise "the decision read waited for the writer"
      end
      decision.versions[tag].should eq(1)

      writer.exec "COMMIT"
      writer.release

      expect_raises(ES::Exception::Conflict) { store.append([joined(course)], decision.condition) }
    end
  else
    pending "runs the append scenarios and races against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
