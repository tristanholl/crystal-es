module ES
  # Delivers events from the event store to reactors and projections, so that
  # any number of application instances can run side by side.
  #
  # Every handler wired in the `EventBus` becomes a subscription: it follows
  # the event store as a log (`EventStore#read_log`), from its own saved
  # position, at its own pace. Exactly one instance processes a subscription at
  # a time, and the instances share the subscriptions out evenly between them.
  #
  # ```
  # subscriptions = ES::Subscriptions.new
  # subscriptions.start
  # # ...
  # subscriptions.stop
  # ```
  #
  # In specs and one-off scripts, `catch_up` runs them in the calling fiber
  # instead, until they have processed everything appended so far.
  #
  # Each delivery happens exactly once, in the order the events were
  # appended:
  #
  # - A reactor runs in a transaction of the event store, together with the
  #   move of its position. The events it appends through the event store it
  #   is given commit with it, or not at all.
  # - A projection declared `atomic: true` applies a batch of events in one
  #   transaction of its database, together with its position (see `write`).
  #   Other projections apply one event at a time and save the position after
  #   it, so an event may be applied twice if the process dies in between.
  #
  # A handler that raises is retried with backoff, and paused after
  # `max_attempts`. Only that subscription stops; the others go on.
  class Subscriptions
    Log = ::Log.for("es.subscriptions")

    alias Handler = ES::Reactor.class | ES::Projection.class

    # The kinds of subscription an instance processes: an application may run
    # its reactors and its projections in separate instances
    @[Flags]
    enum Kinds
      Reactors
      Projections
    end

    private alias LogPosition = ES::EventStore::LogPosition

    # How often a subscription that only skips over events of other types
    # saves how far it got
    private SKIP_SAVE_INTERVAL = 5.seconds

    # The state of one subscription, as `status` reports it
    struct Status
      # `reactor:OnOrderPlaced`, with `#<partition>/<partitions>` when partitioned
      getter name : String
      getter handler : String
      getter partition : Int32
      getter partitions : Int32
      # `running`, `failing` or `paused`
      getter status : String
      getter position : ES::EventStore::LogPosition
      # The newest position of the event store
      getter head : ES::EventStore::LogPosition
      getter attempts : Int32
      getter last_error : String?
      # Whether this instance processes the subscription
      getter? owned : Bool
      # Whether no event the subscription handles remains before the head
      getter? caught_up : Bool

      def initialize(@name, @handler, @partition, @partitions, @status, @position, @head, @attempts, @last_error, @owned, @caught_up)
      end
    end

    private class Settings
      property partitions : Int32 = 1
      property batch_size : Int32? = nil
      property start : Symbol? = nil
      property database : DB::Database? = nil
    end

    # One subscription: a handler, or one partition of it
    private class Unit
      getter name : String
      getter handler : Handler
      getter handles : Array(String)
      getter partition : Int32
      getter partitions : Int32
      getter batch_size : Int32
      getter database : DB::Database?
      getter checkpoints : ES::ProjectionCheckpoints?

      # How far this instance has read, and what is saved
      property position : LogPosition = LogPosition::ZERO
      property saved : LogPosition = LogPosition::ZERO
      property saved_at : Time = Time::UNIX_EPOCH

      property? owned : Bool = false
      property? stopping : Bool = false
      property? refresh : Bool = false
      property done : Channel(Nil) = Channel(Nil).new
      getter wake = Channel(Nil).new(1)

      def initialize(@name, @handler, @handles, @partition, @partitions, @batch_size, @database, @checkpoints)
      end

      def reactor? : Bool
        @handler.is_a?(ES::Reactor.class)
      end

      # As recorded with the heartbeats, and the prefix of the name
      def kind : String
        reactor? ? "reactor" : "projection"
      end

      def partition_filter : {Int32, Int32}?
        @partitions > 1 ? {@partition, @partitions} : nil
      end

      def signal : Nil
        select
        when @wake.send(nil)
        else
          # Already signalled
        end
      end
    end

    # An event a handler failed on, with the error it raised
    private class HandlerFailure < ::Exception
      getter position : LogPosition
      getter error : ::Exception

      def initialize(@position : LogPosition, @error : ::Exception)
        super("#{@error.class.name}: #{@error.message}")
      end
    end

    @settings = {} of Handler => Settings
    @store_elsewhere : Bool? = nil
    @units : Array(Unit)? = nil
    @started = false
    @caught_up = false
    @stopping = false
    @mutex = Mutex.new
    @store : ES::SubscriptionStore

    # All arguments are optional: the bus, event store, event handlers and
    # projection database default to the ones in `ES::Config`, and the store
    # that coordinates the instances comes from the event store.
    #
    # - `listen_url`: the database URL, to wake up on appends at once
    #   (Postgres LISTEN, needs crystal-pg) instead of at the next poll
    # - `poll_interval`: how often to look for new events without a wake-up
    # - `rebalance_interval`: how often to share subscriptions out between the
    #   instances again, and to notice a pause or reset made elsewhere
    # - `max_attempts`, `retry_base_delay`, `retry_max_delay`: retries of a
    #   failing handler, with exponential backoff, before it is paused
    # - `kinds`: which subscriptions this instance processes, `:reactors`,
    #   `:projections` or both (the default). Instances share each kind out
    #   among those that process it. Every handler in the bus stays known, so
    #   `await`, `status` and the operations work for all of them; the bus
    #   should be the same in every instance.
    #
    # ```
    # # An instance that only runs reactors, next to others that run projections
    # subscriptions = ES::Subscriptions.new(kinds: :reactors)
    # ```
    def initialize(
      @bus : ES::EventBus(Handler) = ES::Config.event_bus,
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
      @projection_database : DB::Database? = ES::Config.projection_database?,
      store : ES::SubscriptionStore? = nil,
      listen_url : String? = nil,
      @poll_interval : Time::Span = 1.second,
      @rebalance_interval : Time::Span = 5.seconds,
      @max_attempts : Int32 = 10,
      @retry_base_delay : Time::Span = 1.second,
      @retry_max_delay : Time::Span = 5.minutes,
      @instance_id : String = UUID.v7.to_s,
      @kinds : Kinds = Kinds::All,
    )
      raise ES::Exception::InvalidState.new("max_attempts must be at least 1, got #{@max_attempts}") if @max_attempts < 1
      raise ES::Exception::InvalidState.new("kinds must name reactors, projections or both") if @kinds == Kinds::None
      @store = store || @event_store.subscription_store(listen_url)
    end

    # Adjusts one handler's subscription. Call it before `start`.
    #
    # - `partitions`: split the subscription by aggregate id, so that up to
    #   that many instances process it at once. Events of one aggregate stay
    #   in order. Fixed once the subscription has a position.
    # - `batch_size`: events read at a time, and for an atomic projection,
    #   applied in one transaction
    # - `start`: where a new subscription begins, `:beginning` or `:now`.
    #   Reactors begin `:now` by default, so they never act on history.
    #   Projections begin at the `:beginning` when their table is empty.
    # - `database`: the database of a projection, if not the configured one
    #
    # ```
    # subscriptions.configure(OnOrderPlaced, partitions: 4)
    # ```
    def configure(handler : Handler, partitions : Int32 = 1, batch_size : Int32? = nil, start : Symbol? = nil, database : DB::Database? = nil) : self
      raise ES::Exception::InvalidState.new("configure must be called before the subscriptions are used") if @units
      raise ES::Exception::InvalidState.new("'#{handler.name}' is not subscribed to any event in the event bus") unless handlers.includes?(handler)
      raise ES::Exception::InvalidState.new("partitions must be in 1..1024, got #{partitions}") unless 1 <= partitions <= 1024
      raise ES::Exception::InvalidState.new("batch_size must be at least 1, got #{batch_size}") if batch_size && batch_size < 1
      raise ES::Exception::InvalidState.new("start must be :beginning or :now, got #{start}") if start && !start.in?(:beginning, :now)
      raise ES::Exception::InvalidState.new("database only applies to projections, not '#{handler.name}'") if database && handler.is_a?(ES::Reactor.class)

      settings = @settings[handler] ||= Settings.new
      settings.partitions = partitions
      settings.batch_size = batch_size
      settings.start = start
      settings.database = database
      self
    end

    # Creates what the subscriptions need in the databases. Idempotent;
    # `start` runs it too.
    def setup : Nil
      @store.setup
      units.compact_map(&.checkpoints).uniq! { |checkpoints| {checkpoints.db.object_id, checkpoints.schema} }.each(&.setup)
    end

    # Sets the subscriptions up, gives new ones their starting position, takes
    # this instance's share of them and starts processing in the background.
    # Projection tables must exist, so set the projections up first.
    def start : Nil
      @mutex.synchronize do
        raise ES::Exception::InvalidState.new("Subscriptions were started already") if @started
        raise ES::Exception::InvalidState.new("Subscriptions were stopped") if @stopping

        prepare
        # Raises at once if the store can't tell the kinds apart, instead of
        # in every rebalance
        live_instances unless @kinds == Kinds::All
        @started = true
      end

      rebalance
      spawn(name: "es.subscriptions.rebalance") { rebalance_loop }
      spawn(name: "es.subscriptions.wake") { wake_loop }
    end

    # Stops processing: every subscription finishes the event or batch at
    # hand, then releases its lock for another instance to take over
    #
    # After `catch_up`, it releases the database session the subscriptions
    # took their locks on. On subscriptions neither started nor caught up, it
    # does nothing.
    def stop : Nil
      @mutex.synchronize do
        return if @stopping || !(@started || @caught_up)
        @stopping = true
        @units.try(&.select(&.owned?).each { |unit| release(unit) })
      end

      if @started
        begin
          @store.leave(@instance_id)
        rescue ex
          Log.warn { "Could not deregister instance #{@instance_id}: #{ex.message}" }
        end
      end
      @store.close
    end

    # Processes every subscription in the calling fiber until it has caught up
    # with the event store, then returns. That includes the events the
    # reactors append on the way, and the handlers those reach in turn. Use it
    # in specs and one-off scripts, in place of `start` and `await`: no
    # background fibers, and the error of a failing handler is raised here
    # instead of retried. What it processed is saved like under `start`, with
    # the same guarantees, so calling it again goes on from there.
    #
    # ```
    # subscriptions = ES::Subscriptions.new
    # event_store.append(OrderPlaced.new(...))
    # subscriptions.catch_up
    # # OnOrderPlaced has run, and OrdersProjection holds the order
    # ```
    #
    # The handler's error is raised as it is, unlike the shortened message
    # `start` logs and stores: a database error may carry row values in its
    # later lines. In a script against real data, rescue it and log only its
    # class and first line.
    #
    # Paused subscriptions are left alone. It refuses a subscription another
    # instance is processing, and raises if the subscriptions haven't caught
    # up within `timeout`, e.g. because a reactor keeps appending events that
    # reach it again. It can't be combined with `start`.
    def catch_up(timeout : Time::Span = 30.seconds) : Nil
      @mutex.synchronize do
        raise ES::Exception::InvalidState.new("Subscriptions were started: they process events in the background, use await to wait for them") if @started
        raise ES::Exception::InvalidState.new("Subscriptions were stopped") if @stopping

        prepare
        @caught_up = true
        deadline = Time.utc + timeout
        # Another round as long as one moved: a reactor may have appended
        # events for a subscription that already had its turn
        loop do
          moved = own_units.map { |unit| catch_up(unit, deadline, timeout) }
          break unless moved.any?(&.itself)
        end
      end
    end

    # The state of every subscription, from the shared store
    def status : Array(Status)
      head = @event_store.log_head
      states = @store.all.to_h { |state| {state.name, state} }
      units.compact_map do |unit|
        state = states[unit.name]?
        next if state.nil?

        # A projection's position is its checkpoint only, as for `await`
        position = if checkpoints = unit.checkpoints
                     checkpoints.fetch(unit.name) || LogPosition::ZERO
                   else
                     state.position
                   end
        Status.new(unit.name, unit.handler.name, unit.partition, unit.partitions, state.status, position, head, state.attempts, state.last_error, unit.owned?, reached?(unit, position, head))
      end
    end

    # Stops processing a handler, on whichever instance holds it, until `resume`
    def pause(handler : Handler) : Nil
      refuse_reactor_elsewhere!(handler)
      units_for(handler).each { |unit| @store.update_status(unit.name, ES::SubscriptionStore::PAUSED) }
      refresh(handler)
    end

    # Resumes a paused or failing handler, with its attempts reset
    def resume(handler : Handler) : Nil
      refuse_reactor_elsewhere!(handler)
      units_for(handler).each { |unit| @store.update_status(unit.name, ES::SubscriptionStore::RUNNING) }
      refresh(handler)
    end

    # Moves a failing or paused handler past the event it failed on and
    # resumes it. The handler never processes that event; logged as a warning.
    def skip_failed_event(handler : Handler) : Nil
      refuse_reactor_elsewhere!(handler)
      units_for(handler).each do |unit|
        failed = @store.fetch(unit.name).try(&.failed_position)
        next if failed.nil?

        Log.warn { "Skipping the event at #{failed} for '#{unit.name}'" }
        unit.checkpoints.try { |checkpoints| checkpoints.reset(checkpoints.db, unit.name, failed) }
        @store.reset(unit.name, failed)
      end
      refresh(handler)
    end

    # Truncates a projection's table and replays every event into it. Its
    # readers see the table fill up again; the other subscriptions go on.
    # A projection that is not atomic must be paused first, and resumes once
    # rebuilt.
    def rebuild(projection : ES::Projection.class) : Nil
      rebuilt = units_for(projection)
      unless projection.atomic? || rebuilt.all? { |unit| @store.fetch(unit.name).try(&.paused?) }
        raise ES::Exception::InvalidState.new("'#{projection.name}' is not atomic: pause it, wait for the rebalance interval, then rebuild it")
      end

      table = quoted_table(projection)
      database = projection_database_for(projection)
      # One transaction: an instance applying a batch meanwhile finds its
      # position moved and rolls back, so no row of the old run survives
      database.transaction do |tx|
        tx.connection.exec %(TRUNCATE TABLE #{table} RESTART IDENTITY)
        rebuilt.each { |unit| unit.checkpoints.try(&.reset(tx.connection, unit.name, LogPosition::ZERO)) }
      end
      rebuilt.each { |unit| @store.reset(unit.name, LogPosition::ZERO) }
      refresh(projection)
    end

    # Moves a reactor to the `:beginning` (it processes all history again) or
    # to `:now` (it skips everything appended so far). Projections are rebuilt
    # instead, see `rebuild`.
    def reset(reactor : ES::Reactor.class, to : Symbol) : Nil
      raise ES::Exception::InvalidState.new("to must be :beginning or :now, got #{to}") unless to.in?(:beginning, :now)

      refuse_reactor_elsewhere!(reactor)
      position = to == :beginning ? LogPosition::ZERO : @event_store.log_head
      units_for(reactor).each { |unit| @store.reset(unit.name, position) }
      refresh(reactor)
    end

    # Waits until `handler` has processed everything up to `position`, for
    # instance a projection a reactor is about to read. Returns false if that
    # takes longer than `timeout`.
    #
    # ```
    # def call(event : OrderPlaced)
    #   SUBSCRIPTIONS.await(OrdersProjection, event) || raise "orders projection is behind"
    #   # ... read the projection
    # end
    # ```
    def await(handler : Handler, position : ES::EventStore::LogPosition, timeout : Time::Span = 5.seconds) : Bool
      deadline = Time.utc + timeout
      pending = units_for(handler)
      interval = 10.milliseconds
      loop do
        pending.reject! { |unit| reached?(unit, position) }
        return true if pending.empty?
        return false if Time.utc >= deadline

        sleep Math.min(interval, deadline - Time.utc)
        interval = Math.min(interval * 2, 500.milliseconds)
      end
    end

    # :ditto:
    def await(handler : Handler, event : ES::Event, timeout : Time::Span = 5.seconds) : Bool
      position = event.log_position
      raise ES::Exception::InvalidState.new("'#{event.class.name}' was not delivered by a subscription, so its log position is unknown") if position.nil?

      await(handler, position, timeout)
    end

    # Creates what the subscriptions need and gives new ones their starting
    # position. Every instance whose store is next to the events does so for
    # every reactor, so a new reactor starts when the first such instance of
    # the release does, not when one that runs reactors comes up later. A
    # projection gets its position on an instance that processes projections,
    # where it is checked against its table.
    private def prepare : Nil
      refuse_reactors_elsewhere!
      setup
      units.select { |unit| (unit.reactor? && !store_elsewhere?) || processes?(unit) }.group_by(&.handler).each { |handler, handler_units| create_positions(handler, handler_units) }
    end

    # Processes one subscription up to the head; true if it moved
    private def catch_up(unit : Unit, deadline : Time, timeout : Time::Span) : Bool
      raise ES::Exception::InvalidState.new("'#{unit.name}' is being processed by another instance") unless @store.try_lock(unit.name)

      begin
        state = load(unit)
        return false if state.paused?

        from = unit.position
        loop do
          raise ES::Exception::InvalidState.new("The subscriptions did not catch up within #{timeout}: a reactor may keep appending events that reach it again") if Time.utc >= deadline
          # The lock went with its session: another instance may process the
          # subscription now
          raise ES::Exception::InvalidState.new("Lost the lock of '#{unit.name}' with its database session") unless @store.locks_held?
          break unless process_page(unit)
        end
        skip_to(unit, unit.position, force: true)
        @store.update_status(unit.name, ES::SubscriptionStore::RUNNING) if state.attempts > 0
        unit.position != from
      rescue ex : HandlerFailure
        raise ex.error
      ensure
        @store.unlock(unit.name)
      end
    end

    # Every handler in the bus, in wiring order
    private def handlers : Array(Handler)
      @bus.routes.values.flatten.uniq!
    end

    private def units : Array(Unit)
      @units ||= build_units
    end

    # A reactor's position moves in the event store's transaction, in the
    # subscriptions table of the event store's database. A store elsewhere
    # would read one row and move another, and retry for good.
    private def refuse_reactors_elsewhere! : Nil
      return unless own_units.any?(&.reactor?)
      return unless store_elsewhere?

      raise ES::Exception::InvalidState.new("The subscription store keeps its state elsewhere than next to the events (another database or schema), which only projections can: pass kinds: :projections")
    end

    # A reactor's state on such an instance is not where its position is
    # read and moved, so operations on it would act on the wrong rows
    private def refuse_reactor_elsewhere!(handler : Handler) : Nil
      return unless handler.is_a?(ES::Reactor.class) && store_elsewhere?

      raise ES::Exception::InvalidState.new("'#{handler.name}' is a reactor, whose state is next to the events, not in this instance's subscription store: use an instance whose store is there")
    end

    # Whether the store keeps its state in another database than the events.
    # Asked once: the answer doesn't change while the instance runs.
    private def store_elsewhere? : Bool
      elsewhere = @store_elsewhere
      return elsewhere unless elsewhere.nil?

      @store_elsewhere = @store.same_database?(@event_store) == false
    end

    # The subscriptions of the kinds this instance processes
    private def own_units : Array(Unit)
      units.select { |unit| processes?(unit) }
    end

    private def processes?(unit : Unit) : Bool
      unit.reactor? ? @kinds.reactors? : @kinds.projections?
    end

    private def kind_names : Array(String)
      names = [] of String
      names << "reactor" if @kinds.reactors?
      names << "projection" if @kinds.projections?
      names
    end

    private def units_for(handler : Handler) : Array(Unit)
      found = units.select { |unit| unit.handler == handler }
      raise ES::Exception::InvalidState.new("'#{handler.name}' is not subscribed to any event in the event bus") if found.empty?
      found
    end

    private def build_units : Array(Unit)
      handles = {} of Handler => Array(String)
      @bus.routes.each do |event_class, subscribers|
        subscribers.each { |handler| (handles[handler] ||= [] of String) << event_class.handle }
      end

      handles.flat_map do |handler, handled|
        settings = @settings[handler]? || Settings.new
        kind = handler.is_a?(ES::Reactor.class) ? "reactor" : "projection"
        base = "#{kind}:#{handler.name}"
        database, checkpoints, batch_size = nil, nil, settings.batch_size || 100

        unregistered = handled.reject { |handle| @event_handlers.registered?(handle) }
        raise ES::Exception::InvalidState.new("'#{handler.name}' handles events whose handles are not registered in the event handlers: #{unregistered.uniq.join(", ")}") unless unregistered.empty?

        if projection = handler.as?(ES::Projection.class)
          raise ES::Exception::InvalidState.new("'#{projection.name}' declares init: true; a subscription fills a projection from the beginning by itself, so remove it") if projection.init?
          raise ES::Exception::InvalidState.new("'#{projection.name}' has no valid table name: '#{projection.table}'") unless projection.table.empty? || valid_table?(projection.table)

          database = settings.database || projection_database_for(projection)
          checkpoints = ES::ProjectionCheckpoints.new(database, projection.table_schema)
          batch_size = settings.batch_size || projection.projection_batch_size.to_i32
        end

        Array.new(settings.partitions) do |index|
          name = settings.partitions > 1 ? "#{base}##{index}/#{settings.partitions}" : base
          Unit.new(name, handler, handled.uniq, index, settings.partitions, batch_size, database, checkpoints)
        end
      end
    end

    # Table names end up in SQL, so they must be plain identifiers, and never
    # name a table of the event store itself
    private def valid_table?(table : String) : Bool
      table.matches?(/\A[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?\z/) && !table.downcase.starts_with?("eventstore.")
    end

    # The table quoted the way `define_projection` creates it, so its case is kept
    private def quoted_table(projection : ES::Projection.class) : String
      table = projection.table
      raise ES::Exception::InvalidState.new("'#{projection.name}' has no valid table name: '#{table}'") unless valid_table?(table)

      name = table.split('.').last
      %("#{projection.table_schema}"."#{name}")
    end

    private def projection_database_for(projection : ES::Projection.class) : DB::Database
      @settings[projection]?.try(&.database) || @projection_database ||
        raise ES::Exception::InvalidState.new("No projection database for '#{projection.name}': configure ES::Config.projection_database or pass database: to configure")
    end

    # Gives the subscriptions of a handler their starting position, unless
    # they have one. All partitions start together, so they agree.
    private def create_positions(handler : Handler, handler_units : Array(Unit)) : Nil
      names = handler_units.map(&.name)
      start = (@settings[handler]? || Settings.new).start

      if checkpoints = handler_units.first.checkpoints
        create_projection_positions(handler.as(ES::Projection.class), names, checkpoints, start)
      else
        states = names.map { |name| @store.fetch(name) }
        return if states.all?
        refuse_repartition(handler, names) if states.any?(&.itself) || repartitioned?(names)

        position = start == :beginning ? LogPosition::ZERO : @event_store.log_head
        names.each { |name| @store.create(name, position) }
      end
    end

    # A projection's positions live next to its table; the shared store only
    # mirrors them
    private def create_projection_positions(projection : ES::Projection.class, names : Array(String), checkpoints : ES::ProjectionCheckpoints, start : Symbol?) : Nil
      positions = names.map { |name| checkpoints.fetch(name) }
      if positions.all?
        names.each_with_index { |name, index| @store.create(name, positions[index] || LogPosition::ZERO) }
        return
      end
      refuse_repartition(projection, names) if positions.any?(&.itself) || repartitioned?(names)

      position = projection_start(projection, checkpoints.db, start)
      names.each do |name|
        checkpoints.create(checkpoints.db, name, position)
        @store.create(name, position)
      end
    end

    # Where a new projection subscription starts: from the beginning into an
    # empty table, from now if asked to. A table with rows but no position was
    # filled by something else, e.g. the event bus before subscriptions; replaying
    # into it would apply events twice, so it is refused.
    private def projection_start(projection : ES::Projection.class, database : DB::Database, start : Symbol?) : LogPosition
      return @event_store.log_head if start == :now

      table = projection.table
      empty = table.empty? || database.query_one(%(SELECT NOT EXISTS (SELECT 1 FROM #{quoted_table(projection)} LIMIT 1)), as: Bool)
      return LogPosition::ZERO if empty

      raise ES::Exception::InvalidState.new(
        "'#{projection.name}' has rows in '#{table}' but no subscription position. Either empty the table, so it is filled from the beginning, or configure it with start: :now if it already holds every event so far."
      )
    end

    # Whether positions exist for the handler under other subscription names,
    # i.e. for another number of partitions
    private def repartitioned?(names : Array(String)) : Bool
      !other_partitions(names).empty?
    end

    private def other_partitions(names : Array(String)) : Array(String)
      base = names.first.split('#').first
      @store.all.map(&.name).select { |name| (name == base || name.starts_with?("#{base}#")) && !names.includes?(name) }
    end

    # Some partitions of a handler have positions and some don't, or positions
    # exist for another number of partitions: the partitions were changed
    private def refuse_repartition(handler : Handler, names : Array(String)) : NoReturn
      others = other_partitions(names)
      raise ES::Exception::InvalidState.new(
        "The subscription of '#{handler.name}' has positions for another number of partitions (#{others.join(", ")}). Changing the partitions in place is not supported: stop every instance and remove those positions first."
      )
    end

    private def refresh(handler : Handler) : Nil
      units_for(handler).each do |unit|
        unit.refresh = true
        unit.signal
      end
    end

    private def rebalance_loop : Nil
      until @stopping
        sleep @rebalance_interval
        rebalance
      end
    end

    # Takes this instance's share of the subscriptions, or gives the excess
    # up, and has every subscription it holds read its state again
    private def rebalance : Nil
      @mutex.synchronize do
        next if @stopping

        unless @store.locks_held?
          # The locks went with their session: another instance may hold them
          units.select(&.owned?).each { |unit| release(unit, unlock: false) }
        end

        live = live_instances
        if live.includes?(nil) && !live.all? { |kinds| processes_all?(kinds) }
          Log.warn { "An instance that records no kinds (crystal-es 0.12.1 or earlier) runs next to instances that process only some kinds: it takes less than its share, and some subscriptions may be left without an instance until it is upgraded" }
        end

        if live.all? { |kinds| processes_all?(kinds) }
          # Every instance processes every kind: all are shared out together
          share_out(units, live.size)
        else
          # Each kind among the instances that process it, so an instance that
          # runs only reactors takes all of them when it is the only one,
          # however many run projections
          kind_names.each do |kind|
            share_out(units.select { |unit| unit.kind == kind }, live.count { |kinds| kinds.nil? || kinds.includes?(kind) })
          end
        end

        units.select(&.owned?).each(&.refresh=(true))
      end
    rescue ex
      Log.error(exception: ex) { "Rebalancing subscriptions failed" }
    end

    # Takes this instance's share of `pool` among `instances`, or gives the
    # excess up
    private def share_out(pool : Array(Unit), instances : Int32) : Nil
      instances = Math.max(instances, 1)
      share = (pool.size + instances - 1) // instances
      owned = pool.select(&.owned?)

      if owned.size > share
        owned.last(owned.size - share).each { |unit| release(unit) }
      else
        pool.reject(&.owned?).shuffle!.each do |unit|
          break if pool.count(&.owned?) >= share
          acquire(unit) if @store.try_lock(unit.name)
        end
      end
    end

    # The kinds of every instance alive, nil for one that processes every
    # kind. A store written for an earlier version can't tell them apart,
    # which is fine as long as every instance processes every kind.
    private def live_instances : Array(Array(String)?)
      ttl = @rebalance_interval * 3
      begin
        @store.heartbeat(@instance_id, ttl, kind_names)
      rescue ex : ES::Exception::NotImplemented
        raise ex unless @kinds == Kinds::All

        Array(Array(String)?).new(Math.max(@store.heartbeat(@instance_id, ttl), 1), nil)
      end
    end

    private def processes_all?(kinds : Array(String)?) : Bool
      kinds.nil? || (kinds.includes?("reactor") && kinds.includes?("projection"))
    end

    private def acquire(unit : Unit) : Nil
      unit.owned = true
      unit.stopping = false
      unit.refresh = true
      unit.done = Channel(Nil).new(1)
      spawn(name: "es.subscription #{unit.name}") { run(unit) }
    end

    # Lets the subscription finish the event or batch at hand, then gives up
    # its lock
    private def release(unit : Unit, unlock : Bool = true) : Nil
      unit.stopping = true
      unit.signal
      unit.done.receive
      unit.owned = false
      @store.unlock(unit.name) if unlock
    end

    # Wakes the subscriptions this instance holds when the head moved
    private def wake_loop : Nil
      head = LogPosition::ZERO
      until @stopping
        begin
          @store.wait_for_appends(@poll_interval)
          latest = @event_store.log_head
          if latest != head
            head = latest
            units.each { |unit| unit.signal if unit.owned? }
          end
        rescue ex
          Log.error(exception: ex) { "Waiting for appends failed" }
          sleep @poll_interval
        end
      end
    end

    # Processes one subscription until it is released
    private def run(unit : Unit) : Nil
      paused = false
      attempts = 0

      until unit.stopping?
        begin
          if unit.refresh?
            unit.refresh = false
            state = load(unit)
            paused = state.paused?
            attempts = state.attempts
          end

          if paused
            wait(unit, @rebalance_interval)
            next
          end

          more = process_page(unit)
          if attempts > 0
            @store.update_status(unit.name, ES::SubscriptionStore::RUNNING)
            attempts = 0
          end
          wait(unit, @rebalance_interval) unless more
        rescue ES::Exception::StaleCheckpoint
          # Reset, rebuilt or taken over meanwhile: read the state again
          unit.refresh = true
        rescue ex : HandlerFailure
          attempts += 1
          status = attempts >= @max_attempts ? ES::SubscriptionStore::PAUSED : ES::SubscriptionStore::FAILING
          # Only the shortened message at error level: database errors carry row
          # values, which may be decrypted body data, in their later lines
          Log.error { "'#{unit.name}' failed at #{ex.position} (attempt #{attempts} of #{@max_attempts}): #{failure_message(ex)}" }
          Log.debug(exception: ex.error) { "'#{unit.name}' failed at #{ex.position}" }
          # Work before the failure committed, the failed event or batch did not
          unit.refresh = true

          begin
            @store.record_failure(unit.name, attempts, failure_message(ex), ex.position, status)
          rescue error
            Log.error(exception: error) { "Could not record the failure of '#{unit.name}'" }
          end

          if status == ES::SubscriptionStore::PAUSED
            Log.error { "'#{unit.name}' is paused after #{attempts} failed attempts; resume it or skip the event once fixed" }
          else
            wait(unit, backoff(attempts))
          end
        rescue ex
          Log.error(exception: ex) { "'#{unit.name}' could not read or save its position" }
          unit.refresh = true
          wait(unit, @poll_interval)
        end
      end
    ensure
      unit.done.send(nil)
    end

    # Reads the saved state, for a projection with the position kept next to
    # its data
    private def load(unit : Unit) : ES::SubscriptionStore::State
      state = @store.fetch(unit.name) || raise ES::Exception::InvalidState.new("Subscription '#{unit.name}' has no position")
      position = if checkpoints = unit.checkpoints
                   # Created by `prepare` for every projection processed; gone
                   # only if the checkpoints table was emptied meanwhile.
                   # Neither the store's row (stale then) nor the beginning
                   # (rows may be there) is safe to go on from.
                   checkpoints.fetch(unit.name) || raise ES::Exception::InvalidState.new("Subscription '#{unit.name}' has no checkpoint: restart the instance, so it is created")
                 else
                   state.position
                 end
      unit.position = unit.saved = position
      unit.saved_at = Time.utc
      state
    end

    private def wait(unit : Unit, timeout : Time::Span) : Nil
      select
      when unit.wake.receive
      when timeout(timeout)
      end
    end

    # What is stored as `last_error`: the exception class and the first line
    # of its message, shortened. Database errors put row values in later
    # lines (DETAIL), which must not end up in a table monitoring can read.
    private def failure_message(failure : HandlerFailure) : String
      error = failure.error
      first_line = error.message.to_s.each_line.first? || ""
      "#{error.class.name}: #{first_line}"[0, 300]
    end

    private def backoff(attempts : Int32) : Time::Span
      Math.min(@retry_base_delay * 2 ** (attempts - 1).clamp(0, 20), @retry_max_delay)
    end

    # Processes one page; true if more may follow at once
    private def process_page(unit : Unit) : Bool
      page = @event_store.read_log(unit.position, unit.batch_size, unit.handles, unit.partition_filter)

      completed = if unit.reactor?
                    react(unit, page)
                  elsif unit.handler.as(ES::Projection.class).atomic?
                    project_batch(unit, page)
                  else
                    project_each(unit, page)
                  end

      skip_to(unit, page.last_position) if completed
      page.events.size == unit.batch_size
    end

    # Runs the reactor on each event, each in its own transaction with the move
    # of the position. False if stopped before the end of the page.
    private def react(unit : Unit, page : ES::EventStore::LogPage) : Bool
      reactor = unit.handler.as(ES::Reactor.class)
      page.events.each do |stored|
        return false if unit.stopping?

        position = log_position(stored)
        event = materialize(unit, stored)
        begin
          @event_store.transaction do |store|
            reactor.new(event_store: store, event_handlers: @event_handlers).call(event) if event
            @store.advance(unit.name, unit.saved, position, within: store)
          end
        rescue ex : ES::Exception::StaleCheckpoint
          raise ex
        rescue ex
          raise HandlerFailure.new(position, ex)
        end
        saved(unit, position)
      end
      true
    end

    # Applies a page in one transaction with the projection's position
    private def project_batch(unit : Unit, page : ES::EventStore::LogPage) : Bool
      return true if page.events.empty?

      database, checkpoints = projection_storage(unit)
      projection = unit.handler.as(ES::Projection.class).new(event_handlers: @event_handlers, event_store: @event_store, projection_database: database)
      target = page.last_position
      database.transaction do |tx|
        page.events.each do |stored|
          # A savepoint per event, so an event skipped half-way leaves nothing
          tx.transaction do |savepoint|
            projection.writing_on(savepoint.connection) { apply(unit, projection, stored) }
          end
        rescue ex : ES::Exception::NotFound
          skipped(unit, stored, ex)
        end
        checkpoints.advance(tx.connection, unit.name, unit.saved, target)
      end
      saved(unit, target)
      mirror(unit)
      true
    end

    # Applies a page one event at a time, saving the position after each
    private def project_each(unit : Unit, page : ES::EventStore::LogPage) : Bool
      database, checkpoints = projection_storage(unit)
      projection = unit.handler.as(ES::Projection.class).new(event_handlers: @event_handlers, event_store: @event_store, projection_database: database)
      completed = true
      page.events.each do |stored|
        if unit.stopping?
          completed = false
          break
        end

        position = log_position(stored)
        begin
          apply(unit, projection, stored)
        rescue ex : ES::Exception::NotFound
          skipped(unit, stored, ex)
        end
        checkpoints.advance(database, unit.name, unit.saved, position)
        saved(unit, position)
      end
      mirror(unit)
      completed
    end

    # Applies one event. `ES::Exception::NotFound` passes through for the
    # caller to skip the event once its writes are rolled back: like in a
    # replay, a key destroyed somewhere `apply` reaches, e.g. an aggregate it
    # hydrates, must not stop the projection on every other event.
    private def apply(unit : Unit, projection : ES::Projection, stored : ES::EventStore::Event) : Nil
      position = log_position(stored)
      event = materialize(unit, stored)
      return if event.nil?

      projection.call(event)
    rescue ex : ES::Exception::NotFound | ES::Exception::StaleCheckpoint
      raise ex
    rescue ex
      raise HandlerFailure.new(position || LogPosition::ZERO, ex)
    end

    private def skipped(unit : Unit, stored : ES::EventStore::Event, error : ::Exception) : Nil
      Log.warn { "Skipping event '#{stored.header["event_id"]?}' in '#{unit.name}': #{error.message}" }
    end

    # The typed event, or nil for an event whose body was erased, which no
    # handler can act on
    private def materialize(unit : Unit, stored : ES::EventStore::Event) : ES::Event?
      if stored.body_erased?
        Log.warn { "Skipping event '#{stored.header["event_id"]?}' in '#{unit.name}': its body was erased with its encryption key" }
        return
      end

      event = @event_handlers.materialize(stored)
      event.log_position = stored.log_position
      event
    end

    private def log_position(stored : ES::EventStore::Event) : LogPosition
      stored.log_position || raise ES::Exception::InvalidState.new("Event '#{stored.header["event_id"]?}' has no log position")
    end

    private def projection_storage(unit : Unit) : {DB::Database, ES::ProjectionCheckpoints}
      database = unit.database
      checkpoints = unit.checkpoints
      raise ES::Exception::InvalidState.new("'#{unit.name}' has no projection database") if database.nil? || checkpoints.nil?
      {database, checkpoints}
    end

    private def saved(unit : Unit, position : LogPosition) : Nil
      unit.position = unit.saved = position
      unit.saved_at = Time.utc
    end

    # Moves past events the subscription doesn't handle. Saved only now and
    # then, unless `force`: reading them again after a restart costs little,
    # saving them on every append would cost a write per subscription.
    private def skip_to(unit : Unit, position : LogPosition, force : Bool = false) : Nil
      unit.position = position if position > unit.position
      return unless unit.position > unit.saved
      return if !force && Time.utc - unit.saved_at < SKIP_SAVE_INTERVAL

      position = unit.position

      if checkpoints = unit.checkpoints
        checkpoints.advance(checkpoints.db, unit.name, unit.saved, position)
        saved(unit, position)
        mirror(unit)
      elsif @store.advance(unit.name, unit.saved, position)
        saved(unit, position)
      else
        raise ES::Exception::StaleCheckpoint.new("Subscription '#{unit.name}' is no longer at #{unit.saved}")
      end
    end

    # Copies a projection's position into the shared store, for `status`
    private def mirror(unit : Unit) : Nil
      @store.record_position(unit.name, unit.saved)
    rescue ex
      Log.warn { "Could not record the position of '#{unit.name}': #{ex.message}" }
    end

    # Whether a subscription has processed everything up to `position`: its
    # saved position is past it, or no event it handles lies in between
    # A projection's position is its checkpoint, next to its rows, and only
    # that: a projection without one (new, or rebuilt) hasn't reached
    # anything, whatever a store elsewhere still says about it
    private def reached?(unit : Unit, position : LogPosition) : Bool
      saved = if checkpoints = unit.checkpoints
                checkpoints.fetch(unit.name) || LogPosition::ZERO
              else
                @store.fetch(unit.name).try(&.position) || LogPosition::ZERO
              end
      reached?(unit, saved, position)
    end

    private def reached?(unit : Unit, saved : LogPosition, position : LogPosition) : Bool
      return true if saved >= position

      page = @event_store.read_log(saved, 1, unit.handles, unit.partition_filter)
      if first = page.events.first?
        log_position(first) > position
      else
        page.last_position >= position
      end
    end
  end
end
