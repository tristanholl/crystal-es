module ES
  # Where `ES::Subscriptions` keeps what has to be shared between application
  # instances: each subscription's position and status, who holds which
  # subscription, and which instances are alive. An event store hands out the
  # one that fits it (`EventStore#subscription_store`): Postgres keeps it in the
  # event store's database, in-memory in the process.
  abstract class SubscriptionStore
    RUNNING = "running"
    FAILING = "failing"
    PAUSED  = "paused"

    # What is stored about one subscription
    struct State
      # The subscription's name, e.g. `reactor:OnOrderPlaced`
      getter name : String
      # Everything up to here is processed
      getter position : ES::EventStore::LogPosition
      # `running`, `failing` (retrying after an error) or `paused`
      getter status : String
      # Failed attempts at the current event; 0 while running
      getter attempts : Int32
      # The last error, as `ExceptionClass: message`
      getter last_error : String?
      # The event the last error happened at
      getter failed_position : ES::EventStore::LogPosition?
      getter updated_at : Time

      def initialize(
        @name : String,
        @position : ES::EventStore::LogPosition,
        @status : String = RUNNING,
        @attempts : Int32 = 0,
        @last_error : String? = nil,
        @failed_position : ES::EventStore::LogPosition? = nil,
        @updated_at : Time = Time.utc,
      )
      end

      def paused? : Bool
        @status == PAUSED
      end
    end

    # Creates what the store needs. Idempotent.
    abstract def setup : Nil

    # The state of one subscription, nil if it has none yet
    abstract def fetch(name : String) : State?

    # The state of every subscription
    abstract def all : Array(State)

    # Records a subscription at `position` unless it exists already
    abstract def create(name : String, position : ES::EventStore::LogPosition) : Nil

    # Moves a subscription from `expected` to `position` as part of the
    # transaction of `within`, a store yielded by `EventStore#transaction`.
    # Raises `ES::Exception::StaleCheckpoint` if it is no longer at `expected`,
    # which rolls the transaction back.
    abstract def advance(name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition, within : ES::EventStore) : Nil

    # Moves a subscription from `expected` to `position` on its own. Returns
    # false if it was no longer at `expected`.
    abstract def advance(name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition) : Bool

    # Records a position unconditionally. For subscriptions whose real position
    # is kept elsewhere (projections keep theirs next to their data), so the
    # status here stays informative.
    abstract def record_position(name : String, position : ES::EventStore::LogPosition) : Nil

    # Puts a subscription at `position`, running, with its error cleared
    abstract def reset(name : String, position : ES::EventStore::LogPosition) : Nil

    # Records a failed attempt at `failed_position`
    abstract def record_failure(name : String, attempts : Int32, message : String, failed_position : ES::EventStore::LogPosition, status : String) : Nil

    # Sets the status. `running` also clears attempts and the last error.
    abstract def update_status(name : String, status : String) : Nil

    # Takes the lock that makes this instance the only one processing `name`.
    # Returns false if another instance holds it.
    abstract def try_lock(name : String) : Bool

    # Releases a lock taken by `try_lock`
    abstract def unlock(name : String) : Nil

    # Whether the locks this instance took are still held. False once they may
    # have been lost, e.g. with the database session holding them; every
    # subscription must then stop and take its lock again.
    abstract def locks_held? : Bool

    # Records that the instance is alive and returns how many instances are
    # alive, itself included: those that recorded a heartbeat within `ttl`
    abstract def heartbeat(instance_id : String, ttl : Time::Span) : Int32

    # Removes an instance that stops
    abstract def leave(instance_id : String) : Nil

    # Returns once events may have been appended, at the latest after `timeout`
    abstract def wait_for_appends(timeout : Time::Span) : Nil

    # Releases the connections and locks the store holds
    abstract def close : Nil
  end
end
