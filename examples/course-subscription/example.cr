require "db"
require "pg"

require "../../src/crystal-es"

require "./events/course_defined"
require "./events/student_registered"
require "./events/student_subscribed"
require "./decisions/course_capacity"
require "./decisions/course_subscribers"
require "./decisions/student_course_count"
require "./commands/register_student"
require "./commands/subscribe_student"

# Dynamic consistency boundaries: course subscriptions that respect both the
# course's capacity and a per-student limit, plus unique emails, without an
# aggregate owning either rule.
#
#   crystal run examples/course-subscription/example.cr
#
# DATABASE_URL defaults to the docker compose database.

ES::Config.event_handlers = ES::EventHandlers.new
ES::Config.event_handlers.register(Events::CourseDefined)
ES::Config.event_handlers.register(Events::StudentRegistered)
ES::Config.event_handlers.register(Events::StudentSubscribed)

db = DB.open(ENV.fetch("DATABASE_URL", "postgres://es:es@database:5432/eventstore") + "?max_pool_size=20")

# One application key backs both payload encryption and tag hashing. A random
# one is fine here because the example only reads what the same run wrote; a
# real application loads a stable one (see the financial-transaction example).
application_key = ES::ApplicationEncryptionKeyManager.new(ES::PayloadCipher.random_key)
key_store = ES::KeyStoreAdapters::Postgres.new(db)
key_store.setup
ES::Config.encryption = ES::EncryptionKeyManager.new(key_store, application_key)
ES::Config.tag_hasher = ES::TagHasher.new(application_key)

# Configure the hasher before building the store: it is read at construction
ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
store = ES::Config.event_store
store.setup

# A decision that lost a race is simply taken again on fresh events
def with_retries(&)
  5.times do
    return yield
  rescue ES::Exception::Conflict
    Fiber.yield
  end
  raise ES::Exception::Conflict.new("Gave up after 5 conflicts")
end

# --- Unique emails --------------------------------------------------------------

# Fresh emails on every run, so the example can run against the same database
# again; everything else it touches is keyed by fresh ids anyway.
run = Random::Secure.hex(4)
alice, bob, carol = UUID.v7, UUID.v7, UUID.v7
alice_email = "alice+#{run}@example.com"
{alice => alice_email, bob => "bob+#{run}@example.com", carol => "carol+#{run}@example.com"}.each do |id, email|
  RegisterStudentHandler.new.handle(RegisterStudent.new(id, email))
end

begin
  RegisterStudentHandler.new.handle(RegisterStudent.new(UUID.v7, alice_email))
rescue ex : ES::Exception::InvalidState
  puts "Second registration of #{alice_email} refused: #{ex.message}"
end

registration = store.read(ES::Query.new(ES::QueryItem.new(Events::StudentRegistered, tags: {student_id: alice}))).first
puts "Tags as stored for alice: #{registration.header["tags"]}"
puts "Tag versions stamped on it: #{registration.header["tag_versions"]}"

# --- Capacity and per-student limit under concurrency ----------------------------

course = UUID.v7
store.append(Events::CourseDefined.new(actor_id: nil, command_handler: "DefineCourse", course_id: course, capacity: 2, tags: {course_id: course}))

# Three students try to take the last two seats at the same moment
outcomes = Channel(String).new
[alice, bob, carol].each do |student|
  spawn do
    with_retries { SubscribeStudentHandler.new.handle(SubscribeStudent.new(course, student)) }
    outcomes.send("subscribed")
  rescue ex : ES::Exception::InvalidState
    outcomes.send("refused: #{ex.message}")
  end
end
puts "Concurrent subscriptions to a course with 2 seats: #{Array.new(3) { outcomes.receive }.sort}"

# The student limit spans courses: alice may take two, not three
courses = Array.new(2) { UUID.v7 }
courses.each { |id| store.append(Events::CourseDefined.new(actor_id: nil, command_handler: "DefineCourse", course_id: id, capacity: 10, tags: {course_id: id})) }
courses.each do |id|
  SubscribeStudentHandler.new.handle(SubscribeStudent.new(id, alice))
  puts "alice subscribed to another course"
rescue ex : ES::Exception::InvalidState
  puts "alice refused: #{ex.message}"
end

# --- Erasure ------------------------------------------------------------------

# Destroying alice's key erases her registration body. The event stays in the
# stream with its tags, flagged, so the course keeps its shape.
store.encryption_key_ids(alice).each { |id| ES::Config.encryption.destroy_key(id) }
registration = store.read(ES::Query.new(ES::QueryItem.new(Events::StudentRegistered, tags: {student_id: alice}))).first
puts "alice's registration after erasure: body_erased? = #{registration.body_erased?}, body = #{registration.body.to_json}"
