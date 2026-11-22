module Events
  # Tagged with both ids: it belongs to the course's consistency boundary and to
  # the student's at the same time, which no single aggregate could express.
  class StudentSubscribed < ES::Event
    include ES::EventDSL

    define_event "course", "student_subscribed" do
      attribute :course_id, UUID
      attribute :student_id, UUID
      tag :course_id
      tag :student_id
    end
  end
end
