module ES
  module SubscriptionStoreAdapters
    # Subscription state in the process, for tests and single-process setups.
    # Every `ES::Subscriptions` on the same in-memory event store shares one,
    # which behaves like instances sharing a database.
    class InMemory < ES::SubscriptionStore
      @states = {} of String => ES::SubscriptionStore::State
      @locks = {} of String => Fiber
      @instances = {} of String => Time
      # The kinds each instance processes; one without an entry processes all
      @instance_kinds = {} of String => Array(String)
      @mutex = Mutex.new

      def setup : Nil
      end

      def fetch(name : String) : State?
        @mutex.synchronize { @states[name]? }
      end

      def all : Array(State)
        @mutex.synchronize { @states.values }
      end

      def create(name : String, position : ES::EventStore::LogPosition) : Nil
        @mutex.synchronize { @states[name] ||= State.new(name, position) }
      end

      # Checked at once, so a stale position rolls the transaction back; applied
      # when the transaction commits
      def advance(name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition, within : ES::EventStore) : Nil
        bound = within.as?(ES::EventStoreAdapters::InMemory::Bound)
        raise ES::Exception::InvalidState.new("advance needs a store yielded by an in-memory event store's transaction") if bound.nil?

        raise ES::Exception::StaleCheckpoint.new("Subscription '#{name}' is no longer at #{expected}") unless at?(name, expected)
        bound.store.after_commit { advance(name, expected, position) }
      end

      def advance(name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition) : Bool
        @mutex.synchronize do
          state = @states[name]?
          next false if state.nil? || state.position != expected

          @states[name] = copy(state, position: position)
          true
        end
      end

      def record_position(name : String, position : ES::EventStore::LogPosition) : Nil
        @mutex.synchronize do
          state = @states[name]?
          @states[name] = state ? copy(state, position: position) : State.new(name, position)
        end
      end

      def reset(name : String, position : ES::EventStore::LogPosition) : Nil
        @mutex.synchronize { @states[name] = State.new(name, position) }
      end

      def record_failure(name : String, attempts : Int32, message : String, failed_position : ES::EventStore::LogPosition, status : String) : Nil
        @mutex.synchronize do
          state = @states[name]?
          next if state.nil?

          @states[name] = State.new(name, state.position, status, attempts, message, failed_position)
        end
      end

      def update_status(name : String, status : String) : Nil
        @mutex.synchronize do
          state = @states[name]?
          next if state.nil?

          @states[name] = if status == RUNNING
                            State.new(name, state.position)
                          else
                            State.new(name, state.position, status, state.attempts, state.last_error, state.failed_position)
                          end
        end
      end

      def try_lock(name : String) : Bool
        @mutex.synchronize do
          next false if @locks.has_key?(name)

          @locks[name] = Fiber.current
          true
        end
      end

      def unlock(name : String) : Nil
        @mutex.synchronize { @locks.delete(name) }
      end

      def locks_held? : Bool
        true
      end

      def heartbeat(instance_id : String, ttl : Time::Span) : Int32
        @mutex.synchronize do
          now = Time.utc
          @instances[instance_id] = now
          forget_dead_instances(now, ttl)
          @instances.count { |_, seen| now - seen <= ttl }
        end
      end

      def heartbeat(instance_id : String, ttl : Time::Span, kinds : Array(String)) : Array(Array(String)?)
        # Refused like the Postgres store does, which sends them as one list
        raise ES::Exception::InvalidState.new("kinds must be plain lower-case words, got #{kinds}") if kinds.empty? || !kinds.all?(&.matches?(/\A[a-z_]+\z/))

        @mutex.synchronize do
          now = Time.utc
          @instances[instance_id] = now
          @instance_kinds[instance_id] = kinds.dup
          forget_dead_instances(now, ttl)
          @instances.select { |_, seen| now - seen <= ttl }.keys.map { |id| @instance_kinds[id]?.try(&.dup) }
        end
      end

      # Instances that died without leaving, like the Postgres store does
      private def forget_dead_instances(now : Time, ttl : Time::Span) : Nil
        @instances.select { |_, seen| now - seen > ttl * 10 }.each_key do |id|
          @instances.delete(id)
          @instance_kinds.delete(id)
        end
      end

      def leave(instance_id : String) : Nil
        @mutex.synchronize do
          @instances.delete(instance_id)
          @instance_kinds.delete(instance_id)
        end
      end

      def wait_for_appends(timeout : Time::Span) : Nil
        sleep timeout
      end

      def close : Nil
      end

      private def at?(name : String, expected : ES::EventStore::LogPosition) : Bool
        @mutex.synchronize { @states[name]?.try(&.position) == expected }
      end

      private def copy(state : State, position : ES::EventStore::LogPosition) : State
        State.new(state.name, position, state.status, state.attempts, state.last_error, state.failed_position)
      end
    end
  end
end
