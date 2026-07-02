class Events::StudentSubscribed < ES::Event
  include ::ES::EventDSL

  define_event "student", "student_subscribed" do
    attribute :course_id, UUID
  end
end
