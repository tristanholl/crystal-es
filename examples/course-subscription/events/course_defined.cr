module Events
  class CourseDefined < ES::Event
    include ES::EventDSL

    define_event "course", "course_defined" do
      attribute :course_id, UUID
      attribute :capacity, Int32
      tag :course_id
    end
  end
end
