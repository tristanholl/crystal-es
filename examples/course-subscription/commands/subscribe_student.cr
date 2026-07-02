class Commands::SubscribeStudent < ES::Command
  COURSE_CAPACITY   = 2
  MAX_SUBSCRIPTIONS = 3

  def initialize(
    @course_id : UUID,
    aggregate_id : UUID,
    event_store : ES::EventStore = ES::Config.event_store,
    event_handlers : ES::EventHandlers = ES::Config.event_handlers,
  )
    super(aggregate_id, event_store, event_handlers)
  end

  def call
    # The consistency boundary spans two sequences:
    # - the student aggregate (the primary aggregate of the new event)
    # - the course tag sequence (the course is not an aggregate here)
    student = boundary.load(Student.new(@aggregate_id, event_store: @event_store, event_handlers: @event_handlers))

    course_tag = "course:#{@course_id}"
    subscriptions = 0
    boundary.load(course_tag) do |event|
      subscriptions += 1 if event.header["event_handle"] == "student_subscribed"
    end

    # Business rules across both sequences
    raise ES::Exception::InvalidState.new("Course '#{@course_id}' is full") if subscriptions >= COURSE_CAPACITY
    raise ES::Exception::InvalidState.new("Student '#{@aggregate_id}' reached the subscription limit") if student.state.course_count >= MAX_SUBSCRIPTIONS

    boundary.stage(Events::StudentSubscribed.new(
      actor_id: nil,
      command_handler: self.class.to_s,
      aggregate_id: @aggregate_id,
      aggregate_version: boundary.next_version(student),
      tags: {course_tag => boundary.next_version(course_tag)},
      course_id: @course_id
    ))

    # Atomic conditional append: fails with ES::Exception::Conflict if the student
    # OR the course sequence advanced since they were loaded
    boundary.commit
  end
end
