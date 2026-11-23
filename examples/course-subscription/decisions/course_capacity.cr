module Decisions
  # How many seats the course has, or nil while it isn't defined
  class CourseCapacity < ES::DecisionProjection(Int32?)
    def initialize(@course_id : UUID); end

    def initial_state : State
      nil
    end

    tags course_id: @course_id

    on Events::CourseDefined do |_state, _event|
      body.capacity
    end
  end
end
