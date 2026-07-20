require "db"

require "../../src/crystal-es"

require "./events/student_subscribed"
require "./aggregate"
require "./commands/subscribe_student"

# Initializing event handlers
ES::Config.event_handlers = ES::EventHandlers.new
ES::Config.event_handlers.register(Events::StudentSubscribed)

# The example uses the in-memory store, so it runs without any infrastructure.
# The same code works against ES::EventStoreAdapters::Postgres.
ES::Config.event_store = ES::EventStoreAdapters::InMemory.new
store = ES::Config.event_store

course = UUID.v7
alice = UUID.v7
bob = UUID.v7
carol = UUID.v7

# Alice and Bob take the two seats of the course
Commands::SubscribeStudent.new(course, alice).call
Commands::SubscribeStudent.new(course, bob).call
puts "Seats taken in course '#{course}': #{store.last_version("course:#{course}")}"

# Carol is rejected by the business rule evaluated across the boundary
begin
  Commands::SubscribeStudent.new(course, carol).call
rescue ex : ES::Exception::InvalidState
  puts "Carol rejected: #{ex.message}"
end

# Concurrency: two subscriptions race for the last seat of a fresh course.
# Both boundaries read the course sequence before either of them commits.
contested_course = UUID.v7
course_tag = "course:#{contested_course}"
Commands::SubscribeStudent.new(contested_course, UUID.v7).call

racer_1 = ES::Boundary.new(store)
racer_1.load(course_tag) { }
racer_2 = ES::Boundary.new(store)
racer_2.load(course_tag) { }

racer_1.stage(Events::StudentSubscribed.new(
  actor_id: nil,
  command_handler: "race",
  aggregate_version: 1,
  tags: {course_tag => racer_1.next_version(course_tag)},
  course_id: contested_course
))
racer_1.commit
puts "First racer took the last seat"

racer_2.stage(Events::StudentSubscribed.new(
  actor_id: nil,
  command_handler: "race",
  aggregate_version: 1,
  tags: {course_tag => racer_2.next_version(course_tag)},
  course_id: contested_course
))
begin
  racer_2.commit
rescue ES::Exception::Conflict
  puts "Second racer rejected: the course sequence advanced since it was read"
end
