module Decisions
  # How many courses the student takes, across all courses
  class StudentCourseCount < ES::DecisionProjection(Int32)
    def initialize(@student_id : UUID); end

    def initial_state : State
      0
    end

    tags student_id: @student_id

    on Events::StudentSubscribed do |count, _event|
      count + 1
    end
  end
end
