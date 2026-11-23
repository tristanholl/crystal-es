module Decisions
  # The students subscribed to the course
  class CourseSubscribers < ES::DecisionProjection(Set(UUID))
    def initialize(@course_id : UUID); end

    def initial_state : State
      Set(UUID).new
    end

    tags course_id: @course_id

    on Events::StudentSubscribed do |state, _event|
      state << body.student_id
    end
  end
end
