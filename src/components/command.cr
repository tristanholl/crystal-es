module ES
  # A Command is a pure data record expressing an intent to change state.
  #
  # Following strict event sourcing, a Command carries only the target
  # aggregate and its payload — it has no behavior. The business logic that
  # validates a command, hydrates the aggregate and appends events lives in
  # ES::CommandHandler.
  abstract struct Command
    # Target aggregate the command intends to act upon
    getter aggregate_id : UUID

    def initialize(@aggregate_id : UUID)
    end
  end
end
