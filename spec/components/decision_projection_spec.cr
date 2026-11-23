require "../spec_helper"
require "pg"

# `ES::DecisionProjection` and `EventStore#build_decision_model`. The same
# scenarios run against every adapter; the Postgres ones need a live database
# and only run when ES_TEST_DATABASE_URL is set.

class DecisionCourseDefined < ES::Event
  include ::ES::EventDSL

  define_event "course", "decision_test.course_defined" do
    attribute :course_id, UUID
    attribute :capacity, Int32
    tag :course_id, UUID
  end
end

class DecisionStudentSubscribed < ES::Event
  include ::ES::EventDSL

  define_event "course", "decision_test.student_subscribed" do
    attribute :course_id, UUID
    attribute :student_id, UUID
    tag :course_id, UUID
    tag :student_id, UUID
  end
end

class DecisionStudentRegistered < ES::Event
  include ::ES::EventDSL

  define_event "student", "decision_test.student_registered", encrypted: true do
    attribute :student_id, UUID
    attribute :email, String
    tag :student_id, UUID
    tag :decision_email, String, hashed: true
  end
end

class DecisionCapacity < ES::DecisionProjection(Int32?)
  def initialize(@course_id : UUID); end

  def initial_state : State
    nil
  end

  tags course_id: @course_id

  on DecisionCourseDefined do |_state, _event|
    body.capacity
  end
end

class DecisionSubscribers < ES::DecisionProjection(Array(UUID))
  def initialize(@course_id : UUID); end

  def initial_state : State
    [] of UUID
  end

  tags course_id: @course_id

  on DecisionStudentSubscribed do |state, _event|
    state << body.student_id
  end
end

class DecisionStudentCourses < ES::DecisionProjection(Int32)
  def initialize(@student_id : UUID); end

  def initial_state : State
    0
  end

  tags student_id: @student_id

  on DecisionStudentSubscribed do |count, _event|
    count + 1
  end
end

# Counts registrations under an email, erased ones included
class DecisionEmailRegistrations < ES::DecisionProjection(Int32)
  def initialize(@email : String); end

  def initial_state : State
    0
  end

  tags decision_email: @email

  on DecisionStudentRegistered do |count, _event|
    count + 1
  end

  on_erased DecisionStudentRegistered do |count, _header|
    count + 1
  end
end

# The same question without an erasure handler
class DecisionEmailTaken < ES::DecisionProjection(Bool)
  def initialize(@email : String); end

  def initial_state : State
    false
  end

  tags decision_email: @email

  on DecisionStudentRegistered do |_taken, _event|
    true
  end
end

private def define_course(course_id : UUID, capacity = 10)
  DecisionCourseDefined.new(actor_id: nil, command_handler: "test", course_id: course_id, capacity: capacity, tags: {course_id: course_id})
end

private def subscribe(course_id : UUID, student_id : UUID)
  DecisionStudentSubscribed.new(actor_id: nil, command_handler: "test", course_id: course_id, student_id: student_id, tags: {course_id: course_id, student_id: student_id})
end

private def register(encryption : ES::EncryptionKeyManager, student_id : UUID, email : String, key_id = encryption.create_key)
  DecisionStudentRegistered.new(
    actor_id: nil, command_handler: "test", encryption_key_id: key_id, student_id: student_id, email: email,
    tags: {student_id: student_id, decision_email: email}
  )
end

private def decision_hasher : ES::TagHasher
  ES::TagHasher.new(ES::ApplicationEncryptionKeyManager.new(Bytes.new(32, 9_u8)))
end

# Scenarios shared by every adapter. `build` returns an empty store wired to
# the given encryption and to a tag hasher.
private def decision_scenarios(&build : ES::EncryptionKeyManager? -> ES::EventStore)
  it "folds each projection over the events matching its own query" do
    store = build.call(nil)
    course, other_course, alice, bob = UUID.v7, UUID.v7, UUID.v7, UUID.v7
    store.append([define_course(course, 3), define_course(other_course, 5)])
    store.append([subscribe(course, alice), subscribe(other_course, alice), subscribe(other_course, bob)])

    model = store.build_decision_model(
      capacity: DecisionCapacity.new(course),
      subscribers: DecisionSubscribers.new(course),
      alice_courses: DecisionStudentCourses.new(alice),
    )

    model.state[:capacity].should eq(3)
    model.state[:subscribers].should eq([alice])
    model.state[:alice_courses].should eq(2)
  end

  it "keeps states and bodies out of the model's inspect" do
    store = build.call(nil)
    course, alice = UUID.v7, UUID.v7
    store.append([subscribe(course, alice)])

    model = store.build_decision_model(subscribers: DecisionSubscribers.new(course))

    model.inspect.should eq("ES::DecisionModel(subscribers; 1 events)")
    model.inspect.should_not contain(alice.to_s)
  end

  it "folds in append order" do
    store = build.call(nil)
    course = UUID.v7
    store.append([define_course(course, 3)])
    store.append([define_course(course, 7)])

    store.build_decision_model(capacity: DecisionCapacity.new(course)).state[:capacity].should eq(7)
  end

  it "starts every fold from a fresh initial state" do
    store = build.call(nil)
    course = UUID.v7
    store.append([subscribe(course, UUID.v7)])

    2.times { store.build_decision_model(subscribers: DecisionSubscribers.new(course)).state[:subscribers].size.should eq(1) }
  end

  it "returns initial states for a boundary without events" do
    store = build.call(nil)

    model = store.build_decision_model(capacity: DecisionCapacity.new(UUID.v7), courses: DecisionStudentCourses.new(UUID.v7))

    model.state.should eq({capacity: nil, courses: 0})
    model.decision.events.should be_empty
  end

  it "guards the append with every tag the projections read" do
    store = build.call(nil)
    course, alice = UUID.v7, UUID.v7
    store.append([define_course(course)])

    model = store.build_decision_model(subscribers: DecisionSubscribers.new(course), courses: DecisionStudentCourses.new(alice))
    model.condition.stored_tags.map(&.[0]).sort!.should eq(["course_id:#{course}", "student_id:#{alice}"])

    # alice subscribes elsewhere after the decision was read
    store.append([subscribe(UUID.v7, alice)])

    expect_raises(ES::Exception::Conflict) { store.append([subscribe(course, alice)], model.condition) }
    store.append([subscribe(course, alice)], store.build_decision_model(subscribers: DecisionSubscribers.new(course), courses: DecisionStudentCourses.new(alice)).condition)
  end

  it "matches a hashed tag given in plaintext" do
    encryption = test_encryption
    store = build.call(encryption)
    store.append([register(encryption, UUID.v7, "jane@example.com")])

    store.build_decision_model(registrations: DecisionEmailRegistrations.new("jane@example.com")).state[:registrations].should eq(1)
    store.build_decision_model(registrations: DecisionEmailRegistrations.new("john@example.com")).state[:registrations].should eq(0)
  end

  it "folds an erased event through on_erased" do
    encryption = test_encryption
    store = build.call(encryption)
    key_id = encryption.create_key
    store.append([register(encryption, UUID.v7, "jane@example.com", key_id), register(encryption, UUID.v7, "jane@example.com")])
    encryption.destroy_key(key_id)

    store.build_decision_model(registrations: DecisionEmailRegistrations.new("jane@example.com")).state[:registrations].should eq(2)
  end

  it "refuses to fold an erased event without on_erased" do
    encryption = test_encryption
    store = build.call(encryption)
    key_id = encryption.create_key
    store.append([register(encryption, UUID.v7, "jane@example.com", key_id)])
    encryption.destroy_key(key_id)

    expect_raises(ES::Exception::InvalidState, /erased.*on_erased DecisionStudentRegistered/) do
      store.build_decision_model(taken: DecisionEmailTaken.new("jane@example.com"))
    end
  end
end

describe ES::DecisionProjection do
  it "derives its query item from its handlers and tags" do
    course = UUID.v7
    item = DecisionSubscribers.new(course).query_item

    item.types.should eq(["decision_test.student_subscribed"])
    item.tags.map(&.to_s).should eq(["course_id:#{course}"])
  end

  it "keeps a hashed tag value out of its query item's string form" do
    DecisionEmailTaken.new("jane@example.com").query_item.tags.map(&.to_s).should eq(["decision_email:[hashed]"])
  end

  it "keeps tag values out of inspect and to_s" do
    projection = DecisionEmailTaken.new("jane@example.com")

    projection.inspect.should eq("DecisionEmailTaken(decision_email)")
    projection.to_s.should_not contain("jane")
  end

  it "refuses an event of a class it does not handle" do
    stored = ES::EventStore::Event.new(JSON.parse(define_course(UUID.v7).header.to_json), JSON.parse("{}"))

    expect_raises(ES::Exception::InvalidState, /does not handle 'decision_test.course_defined'/) do
      DecisionSubscribers.new(UUID.v7).fold([stored])
    end
  end
end

describe "ES::EventStoreAdapters::InMemory#build_decision_model" do
  decision_scenarios { |encryption| ES::EventStoreAdapters::InMemory.new(encryption: encryption, tag_hasher: decision_hasher).as(ES::EventStore) }
end

module PostgresDecisionSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.fresh_store(encryption : ES::EncryptionKeyManager?) : ES::EventStore
    db = @@db ||= DB.open(URL || raise "ES_TEST_DATABASE_URL is not set")
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    store = ES::EventStoreAdapters::Postgres.new(db, encryption, decision_hasher)
    store.setup
    store
  end
end

describe "ES::EventStoreAdapters::Postgres#build_decision_model" do
  if PostgresDecisionSpec::URL
    decision_scenarios { |encryption| PostgresDecisionSpec.fresh_store(encryption) }
  else
    pending "runs the decision scenarios against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
