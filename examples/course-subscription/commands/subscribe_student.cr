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
class SubscribeStudentHandler < ES::CommandHandler(SubscribeStudent)
  MAX_COURSES_PER_STUDENT = 2

  def handle(command : SubscribeStudent)
    course_id = command.aggregate_id
    student_id = command.student_id

    query = ES::Query.new(
      ES::QueryItem.new(Events::CourseDefined, Events::StudentSubscribed, tags: {course_id: course_id}),
      ES::QueryItem.new(Events::StudentSubscribed, tags: {student_id: student_id}),
    )
    events = @event_store.read(query)

    capacity = nil
    course_subscriptions = 0
    student_subscriptions = 0

    events.each do |stored|
      case event = @event_handlers.materialize(stored)
      when Events::CourseDefined
        capacity = event.body.as(Events::CourseDefined::Body).capacity
      when Events::StudentSubscribed
        body = event.body.as(Events::StudentSubscribed::Body)
        raise ES::Exception::InvalidState.new("Student is already subscribed") if body.course_id == course_id && body.student_id == student_id
        course_subscriptions += 1 if body.course_id == course_id
        student_subscriptions += 1 if body.student_id == student_id
      end
    end

    raise ES::Exception::NotFound.new("Course '#{course_id}' does not exist") if capacity.nil?
    raise ES::Exception::InvalidState.new("Course is full") if course_subscriptions >= capacity
    raise ES::Exception::InvalidState.new("Student takes too many courses") if student_subscriptions >= MAX_COURSES_PER_STUDENT

    @event_store.append(
      [Events::StudentSubscribed.new(actor_id: nil, command_handler: "SubscribeStudent", course_id: course_id, student_id: student_id)],
      ES::AppendCondition.new(query, after: events.last?.try(&.position))
    )
  end
end
