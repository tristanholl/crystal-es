struct SubscribeStudent < ES::Command
  getter student_id : UUID

  def initialize(@aggregate_id : UUID, @student_id : UUID)
  end
end

# A subscription has to respect two limits at once: the course's capacity and
# the number of courses one student may take. With aggregates, one of the two
# would have to own the other, or the check would race. With a dynamic
# consistency boundary, the decision reads exactly the events it depends on —
# across both — and appends on the condition that none of them changed.
#
# Each question is a small decision projection. `build_decision_model` reads
# the events of all three in one decision read and folds each over its own, so
# the events read, the folds and the append condition can't drift apart.
class SubscribeStudentHandler < ES::CommandHandler(SubscribeStudent)
  MAX_COURSES_PER_STUDENT = 2

  def handle(command : SubscribeStudent)
    course_id = command.aggregate_id
    student_id = command.student_id

    model = @event_store.build_decision_model(
      capacity: Decisions::CourseCapacity.new(course_id),
      subscribers: Decisions::CourseSubscribers.new(course_id),
      student_courses: Decisions::StudentCourseCount.new(student_id),
    )
    capacity = model.state[:capacity]
    subscribers = model.state[:subscribers]

    raise ES::Exception::NotFound.new("Course '#{course_id}' does not exist") if capacity.nil?
    raise ES::Exception::InvalidState.new("Student is already subscribed") if subscribers.includes?(student_id)
    raise ES::Exception::InvalidState.new("Course is full") if subscribers.size >= capacity
    raise ES::Exception::InvalidState.new("Student takes too many courses") if model.state[:student_courses] >= MAX_COURSES_PER_STUDENT

    @event_store.append(
      [Events::StudentSubscribed.new(
        actor_id: nil, command_handler: "SubscribeStudent", course_id: course_id, student_id: student_id,
        tags: {course_id: course_id, student_id: student_id}
      )],
      model.condition
    )
  end
end
