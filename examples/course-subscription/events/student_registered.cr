module Events
  # The email is personal data, so the body is encrypted and the tag is hashed:
  # the store can still tell whether an email is taken without holding it in
  # the clear.
  class StudentRegistered < ES::Event
    include ES::EventDSL

    define_event "student", "student_registered", encrypted: true do
      attribute :student_id, UUID
      attribute :email, String
      tag :student_id
      tag :email, hashed: true
    end
  end
end
