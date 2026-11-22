struct RegisterStudent < ES::Command
  getter email : String

  def initialize(@aggregate_id : UUID, @email : String)
  end
end

# Emails must be unique. The decision depends on one fact: has any student
# registered with this email? `after: nil` asks exactly that at append time.
class RegisterStudentHandler < ES::CommandHandler(RegisterStudent)
  def handle(command : RegisterStudent)
    query = ES::Query.new(ES::QueryItem.new(Events::StudentRegistered, tags: {email: command.email}))
    raise ES::Exception::InvalidState.new("Email is already registered") unless @event_store.read(query).empty?

    @event_store.append(
      [Events::StudentRegistered.new(
        actor_id: nil, command_handler: "RegisterStudent",
        encryption_key_id: ES::Config.encryption.create_key,
        aggregate_id: command.aggregate_id,
        student_id: command.aggregate_id, email: command.email,
        tags: {student_id: command.aggregate_id, email: command.email}
      )],
      ES::AppendCondition.new(query)
    )
  end
end
