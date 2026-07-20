class Student < ES::Aggregate
  @@type = "student"

  struct State < ES::Aggregate::State
    property course_count : Int32 = 0
  end

  getter state : State

  def initialize(
    aggregate_id : UUID,
    @event_store : ES::EventStore = ES::Config.event_store,
    @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
  )
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  # Apply 'Events::StudentSubscribed' to the aggregate state
  def apply(event : Events::StudentSubscribed)
    @state.increase_version(event.header.aggregate_version)

    @state.course_count += 1
  end
end
