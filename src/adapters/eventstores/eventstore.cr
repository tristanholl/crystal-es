module ES
  abstract class EventStore
    abstract def append(event : ES::Event)
    abstract def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
    abstract def fetch_event(event_id : UUID) : ES::EventStore::Event
    abstract def setup
    abstract def each_event(until_event_id : UUID? = nil, batch_size : Int64 = 1000, &block : ES::EventStore::Event ->)
    abstract def last_event_id : UUID?

    # The encryption keys used across an aggregate's stream.
    #
    # This is the reverse lookup an erasure request needs. It lives here rather than
    # on the keystore so that the key table never has to hold a business identifier:
    # references run one way only, from an event header to a key.
    #
    # ```
    # store.encryption_key_ids(aggregate_id).each { |id| key_manager.destroy_key(id) }
    # ```
    #
    # A subject whose data spans several aggregates is the application's to map — it
    # holds the key id on its own record and calls `destroy_key` directly.
    abstract def encryption_key_ids(aggregate_id : UUID) : Array(UUID)

    # Returns the events matching a query, in the order they were appended, each
    # with its `position` in the store.
    #
    # This is the read side of a dynamic consistency boundary: the events a
    # decision depends on, selected by type and tag rather than by aggregate.
    # `after` returns only events past that position, `limit` caps the count.
    #
    # Positions order events and page through results; they play no part in
    # consistency. They are not commit-ordered — two concurrent appends may
    # commit in the opposite order of their positions — so a position is no
    # cursor for following the store either: reading again `after` the last
    # position seen can miss an event that committed late with a lower one.
    # Consistency rests on tag versions instead (see `read_for_decision`).
    #
    # An event whose encryption key was destroyed still comes back, with its
    # header but without its body (`body_erased?`). Erasure removes the data, not
    # the fact that something happened: the stream keeps its shape, a course still
    # counts a subscription whose student was erased, and can show it as such.
    # Raising would leave every boundary touching an erased subject undecidable
    # for good; skipping would let it be decided on events that silently went
    # missing.
    #
    # Not abstract, so event store adapters written before queries existed still
    # compile; they raise when asked.
    def read(query : ES::Query, after : Int64? = nil, limit : Int32? = nil) : Array(ES::EventStore::Event)
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support queries")
    end

    # Returns the events matching a query together with the current version of
    # every tag the query names, read in one snapshot so the two agree. Its
    # `condition` guards the append the decision leads to: it fails if anything
    # carrying one of those tags was appended since.
    #
    # Every item of the query must name tags — a version exists per tag, so an
    # item selecting by type alone has nothing that could detect a change.
    #
    # Not abstract, so event store adapters written before decisions existed
    # still compile; they raise when asked.
    def read_for_decision(query : ES::Query) : ES::Decision
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support decision reads")
    end

    # Builds a decision from one or more `ES::DecisionProjection`s, each under a
    # name: reads the events of all of them in one decision read, folds each
    # projection over the events matching its own query, and returns their
    # states by name together with the condition guarding the append.
    #
    # ```
    # model = event_store.build_decision_model(
    #   capacity: CourseCapacity.new(course_id),
    #   subscriptions: CourseSubscriptions.new(course_id),
    #   student_courses: StudentCourseCount.new(student_id),
    # )
    # raise "Course is full" if model.state[:subscriptions].size >= (model.state[:capacity] || 0)
    # event_store.append([event], model.condition)
    # ```
    #
    # Small projections that each answer one question keep the boundary as
    # narrow as the decision needs. One read serves them all, so their states
    # agree with each other and with the condition. An event matching several
    # projections is folded into each.
    #
    # Built on `read_for_decision`, so it works with every adapter that
    # implements that.
    def build_decision_model(**projections : **T) forall T
      {% raise "build_decision_model needs at least one projection, e.g. build_decision_model(capacity: CourseCapacity.new(course_id))" if T.keys.empty? %}
      {% for key, type in T %}
        {% raise "build_decision_model: '#{key}' is a #{type}, not an ES::DecisionProjection" unless type < ::ES::DecisionProjection %}
      {% end %}

      decision = read_for_decision(ES::Query.new(*projections.values.map(&.query_item)))
      state = {% begin %}
                {
                  {% for key in T.keys %}
                    {{ key.stringify }}: fold_matching(projections[{{ key.symbolize }}], decision.events),
                  {% end %}
                }
              {% end %}
      ES::DecisionModel.new(state, decision)
    end

    # Folds a projection over the events matching its own query, with its tags
    # encoded as this store encodes them
    protected def fold_matching(projection : ES::DecisionProjection, events : Array(ES::EventStore::Event))
      items = encode_query(ES::Query.new(projection.query_item))
      projection.fold(events.select { |event| event_matches?(event.header, items) })
    end

    # Whether a stored header matches any item of an encoded query
    protected def event_matches?(header : JSON::Any, items : Array(EncodedQueryItem)) : Bool
      handle = header["event_handle"].as_s
      tags = header["tags"]?.try(&.as_a.map(&.as_s)) || [] of String

      items.any? do |item|
        (item.types.empty? || item.types.includes?(handle)) && item.tags.all? { |tag| tags.includes?(tag) }
      end
    end

    # Appends several events atomically — all or none — and, given a condition,
    # only if every tag it names is still at the version it expects. Raises
    # `ES::Exception::Conflict` otherwise, and appends nothing.
    #
    # This is the write side of a dynamic consistency boundary: read what a
    # decision depends on, decide, then append on the condition that none of it
    # changed in between. Every tagged append raises the version of each of its
    # tags and stamps the new values into the stored header. Returns the
    # position of the last appended event.
    #
    # Takes an array of any event type — `[StudentSubscribed.new(...)]` is an
    # `Array(StudentSubscribed)`, which Crystal would not pass where an
    # `Array(ES::Event)` is expected.
    def append(events : Array(T), condition : ES::AppendCondition? = nil) : Int64 forall T
      {% raise "append expects an array of events, got Array(#{T})" unless T <= ES::Event %}
      append_batch(events.map(&.as(ES::Event)), condition)
    end

    # What adapters implement for `append(events, condition)`. Not abstract, so
    # adapters written before conditional appends existed still compile; they
    # raise when asked.
    protected def append_batch(events : Array(ES::Event), condition : ES::AppendCondition?) : Int64
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support batch or conditional appends")
    end

    # An event ready to be stored: its body, and its tags in stored form. The
    # header is only built once the tag versions are known.
    protected record EncodedEvent, event : ES::Event, body : String, tags : Array(String)

    # Encodes a batch before anything is written, so a hashing or encryption
    # failure on any one event leaves the store untouched
    protected def encode_events(events : Array(ES::Event)) : Array(EncodedEvent)
      raise ES::Exception::InvalidState.new("Nothing to append: the batch is empty") if events.empty?

      events.map do |event|
        EncodedEvent.new(event, encode_body(event), stored_tags(event))
      end
    end

    # The header JSON to persist, carrying the event's stored tags and the
    # versions this append assigned them. Built from the event's own header with
    # both replaced, so neither can be smuggled in on the event as given.
    protected def stored_header(event : EncodedEvent, versions : Hash(String, Int64)) : String
      event.event.header.with_tags(event.tags, versions).to_json
    end

    # Assigns tag versions to a batch in order: each event raises every one of
    # its tags by one, starting from `current`, which is updated in place to the
    # versions after the batch. Returns each event's versions.
    protected def assign_versions(encoded : Array(EncodedEvent), current : Hash(String, Int64)) : Array(Hash(String, Int64))
      encoded.map do |event|
        versions = {} of String => Int64
        event.tags.each do |tag|
          version = current.fetch(tag, 0_i64) + 1
          current[tag] = version
          versions[tag] = version
        end
        versions
      end
    end

    # The versions a condition expects, by stored tag
    protected def expected_versions(condition : ES::AppendCondition) : Hash(String, Int64)
      expected = {} of String => Int64
      entries = condition.tags.map { |tag, version| {encode_tag(tag), version, tag.key} } +
                condition.stored_tags.map { |tag, version| {tag, version, tag.partition(':')[0]} }

      entries.each do |tag, version, key|
        # Messages name keys only, never values, which may be personal data
        raise ES::Exception::InvalidState.new("Append condition expects tag '#{key}' at two different versions") if expected.has_key?(tag) && expected[tag] != version
        expected[tag] = version
      end

      expected
    end

    # The first tag whose current version differs from the expected one, or nil
    protected def version_mismatch(expected : Hash(String, Int64), current : Hash(String, Int64)) : String?
      expected.each do |tag, version|
        return tag if current.fetch(tag, 0_i64) != version
      end
      nil
    end

    # The error raised when an append condition fails. Names the tag key only,
    # never its value, which may be personal data.
    protected def append_conflict(tag : String) : ES::Exception::Conflict
      ES::Exception::Conflict.new(
        "Append condition failed: tag '#{tag.partition(':')[0]}' is no longer at the expected version",
        status_code: HTTP::Status::CONFLICT
      )
    end

    # The stored tags a decision read captures versions for. Refuses an item
    # without tags: nothing could tell whether what it selects has changed.
    protected def decision_tags(items : Array(EncodedQueryItem)) : Array(String)
      raise ES::Exception::InvalidState.new("A decision read needs every query item to name tags; an item selecting by type alone cannot detect a change") if items.any?(&.tags.empty?)

      items.flat_map(&.tags).uniq!
    end

    # Refuses read options that have no sensible meaning
    protected def validate_read_options(after : Int64?, limit : Int32?)
      raise ES::Exception::InvalidState.new("after must not be negative, got #{after}") if after && after < 0
      raise ES::Exception::InvalidState.new("limit must be at least 1, got #{limit}") if limit && limit < 1
    end

    # The newest position `read_log` may return: every event at or before it
    # belongs to a finished transaction, so nothing can still appear before it.
    # `LogPosition::ZERO` for an empty store.
    #
    # Not abstract, so event store adapters written before subscriptions existed
    # still compile; they raise when asked.
    def log_head : LogPosition
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support reading the store as a log")
    end

    # Reads the store as one log: the events after `after`, oldest first, up to
    # `limit` of them, and never past `log_head`. This is what subscriptions
    # follow, and the one read that is safe to resume from a saved position:
    # positions come in transaction order, and an event only becomes readable
    # once nothing can commit before it any more, so a reader never skips one.
    #
    # `handles` keeps only events of those types, `partition` (index, count)
    # only those whose aggregate id hashes to that partition. The page's
    # `last_position` is where the read got to, past any events the filters
    # left out, so a reader can move on even when none of them matched.
    #
    # ```
    # page = event_store.read_log(after: checkpoint, limit: 100, handles: [OrderPlaced.handle])
    # page.events.each { |event| handle(event) }
    # checkpoint = page.last_position
    # ```
    #
    # An event whose encryption key was destroyed comes back header only,
    # flagged `body_erased?`, like in `read`.
    def read_log(after : LogPosition, limit : Int32 = 1000, handles : Array(String)? = nil, partition : {Int32, Int32}? = nil) : LogPage
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support reading the store as a log")
    end

    # Runs the block in one transaction and yields an event store bound to it:
    # every append made through that store commits when the block returns, or
    # none does if it raises, and its reads see its own appends. Returns the
    # block's value.
    #
    # ```
    # event_store.transaction do |store|
    #   ReserveStockHandler.new(event_store: store).handle(reserve)
    #   ChargePaymentHandler.new(event_store: store).handle(charge)
    # end
    # ```
    #
    # Only work done through the yielded store joins the transaction. A command
    # handler that falls back to `ES::Config.event_store` writes outside it.
    def transaction(& : ES::EventStore -> T) : T forall T
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support transactions")
    end

    # The store that coordinates `ES::Subscriptions` on top of this event store:
    # positions, status, locks and the instances taking part. `listen_url` lets
    # the Postgres one wake up on appends instead of polling.
    def subscription_store(listen_url : String? = nil) : ES::SubscriptionStore
      raise ES::Exception::NotImplemented.new("#{self.class.name} does not support subscriptions")
    end

    # Refuses log read options that have no sensible meaning
    protected def validate_log_options(limit : Int32, partition : {Int32, Int32}?)
      raise ES::Exception::InvalidState.new("limit must be at least 1, got #{limit}") if limit < 1
      if part = partition
        index, count = part
        raise ES::Exception::InvalidState.new("partition count must be at least 1, got #{count}") if count < 1
        raise ES::Exception::InvalidState.new("partition index must be in 0...#{count}, got #{index}") unless 0 <= index < count
      end
    end

    @encryption : ES::EncryptionKeyManager? = nil
    @tag_hasher : ES::TagHasher? = nil

    # A place in the store read as a log (`read_log`). Positions order events by
    # the transaction that appended them, then by their position within it.
    # Unlike `Event#position`, they are safe to resume reading from.
    struct LogPosition
      include Comparable(LogPosition)

      # The appending transaction; 0 for events stored before log positions existed
      getter transaction_id : Int64
      # The event's position (`Event#position`)
      getter id : Int64

      def initialize(@transaction_id : Int64, @id : Int64)
      end

      # Before the first event
      ZERO = new(0_i64, 0_i64)

      def <=>(other : LogPosition) : Int32
        {transaction_id, id} <=> {other.transaction_id, other.id}
      end

      def to_s(io : IO) : Nil
        io << transaction_id << ':' << id
      end
    end

    # One page of `read_log`: the events read, and how far the read got
    record LogPage, events : Array(Event), last_position : LogPosition

    struct Event
      getter header : JSON::Any
      getter body : JSON::Any

      # Position of the event in the store's global order, where the read that
      # returned it knows it. Positions only ever increase, but are not gapless.
      getter position : Int64?

      # Whether the body was encrypted under a key that has since been destroyed.
      # The header — type, tags, position — is intact; the body is JSON null.
      getter? body_erased : Bool

      # Position of the event in the store read as a log, set by `read_log`
      getter log_position : LogPosition?

      # Initialize Event with header and body
      def initialize(
        @header : JSON::Any,
        @body : JSON::Any,
        @position : Int64? = nil,
        @body_erased : Bool = false,
        @log_position : LogPosition? = nil,
      )
      end
    end

    # A query item with its tags in stored form, ready to match against headers
    protected record EncodedQueryItem, types : Array(String), tags : Array(String)

    # Encodes the tags of every item of a query the way `stored_tags` encodes
    # them on append, so a query for a hashed tag compares digests, never values
    protected def encode_query(query : ES::Query) : Array(EncodedQueryItem)
      query.items.map do |item|
        EncodedQueryItem.new(item.types, item.tags.map { |tag| encode_tag(tag) })
      end
    end

    # The tags an event is stored with — the ones its stored header carries, and
    # the ones whose versions its append raises. Deriving both here keeps them
    # from drifting apart: a tag stored without its version raised would slip
    # past conditional appends.
    #
    # The tags are derived in the store rather than when the event is built,
    # because a hashed tag needs the store's hasher. That also means the
    # plaintext value of a hashed tag never sits on a header that could be
    # serialized elsewhere.
    #
    # An event built through `define_event` brings plaintext tags, encoded here.
    # One read back brings stored tags in its header instead, kept as they are —
    # but only once checked, since a header can also come from elsewhere (a
    # queue message, a copy tool): every key must be declared by the event, and
    # a hashed key must carry a digest. Otherwise a plaintext value would be
    # stored under a key declared hashed, or an event slipped into a boundary it
    # does not belong to.
    protected def stored_tags(event : ES::Event) : Array(String)
      plain = event.tags
      stored = event.header.tags

      # Messages name keys only, never values, which may be personal data
      raise ES::Exception::InvalidState.new("'#{event.class.name}' carries both tags to encode and stored tags; build it with one or the other") if !plain.empty? && !stored.empty?
      return plain.map { |tag| encode_tag(tag) } unless plain.empty?

      declared = event.class.tag_definitions.to_h
      stored.each do |tag|
        key, _, value = tag.partition(':')
        hashed = declared[key]?
        raise ES::Exception::InvalidState.new("'#{event.class.name}' carries a stored tag '#{key}' it does not declare") if hashed.nil?
        raise ES::Exception::InvalidState.new("'#{event.class.name}' carries a stored tag '#{key}' that is declared hashed but holds no digest") if hashed && !value.matches?(ES::TagHasher::STORED_DIGEST)
      end

      stored
    end

    # Returns the stored form of one tag
    protected def encode_tag(tag : ES::Tag) : String
      return tag.plain unless tag.hashed?

      hasher = @tag_hasher
      # Refusing is the only safe answer: storing the value in the clear would
      # leak exactly what `hashed: true` was declared to protect.
      raise ES::Exception::InvalidState.new("Tag '#{tag.key}' is declared hashed but this event store has no tag hasher configured") if hasher.nil?

      hasher.encode(tag)
    end

    # Returns the body JSON to persist, encrypting it when the event names a key
    protected def encode_body(event : ES::Event) : String
      encryption = @encryption

      if encryption.nil?
        # Refusing here is the whole value of declaring an event encrypted: without
        # it, a misconfigured store would silently write protected data in the clear.
        raise ES::Exception::InvalidState.new("'#{event.class.name}' is declared encrypted but this event store has no encryption configured") if event.class.encrypted?
        return event.body.to_json
      end

      encryption.seal(event)
    end

    # Turns a stored row into an event, decrypting the body when its header names a
    # key. A store always hands back plaintext, so nothing downstream has to know
    # that encryption exists. If the key was destroyed, `ES::Exception::NotFound`
    # raises straight through — the same as any other missing row.
    protected def decode(header : JSON::Any, body : JSON::Any, position : Int64? = nil, log_position : LogPosition? = nil) : ES::EventStore::Event
      parsed_header = ES::Event::Header.from_json(header.to_json)
      return ES::EventStore::Event.new(header, body, position, log_position: log_position) if parsed_header.encryption_key_id.nil?

      encryption = @encryption
      raise ES::Exception::DependencyUnavailable.new("Event body is encrypted but this event store has no encryption configured") if encryption.nil?

      ES::EventStore::Event.new(header, encryption.open(body, parsed_header), position, log_position: log_position)
    end

    # Same as #decode, but returns an event whose body was encrypted under a
    # destroyed key as header only, flagged `body_erased?`. #read uses this so
    # erasing a subject's data leaves the shape of every stream it appears in
    # intact.
    #
    # The key store raises the same `NotFound` for a key that was destroyed and
    # one that never existed in this environment, so a misconfigured key store
    # also reads as erased here.
    protected def decode_or_erase(header : JSON::Any, body : JSON::Any, position : Int64? = nil, log_position : LogPosition? = nil) : ES::EventStore::Event
      decode(header, body, position, log_position)
    rescue ES::Exception::NotFound
      ES::EventStore::Event.new(header, JSON::Any.new(nil), position, body_erased: true, log_position: log_position)
    end

    # Same as #decode, but tolerates a body encrypted under a key that has since
    # been destroyed. Only some events in a stream may be encrypted at all —
    # typically the ones carrying PII — so one shredded key must not stop a
    # projector from replaying everything else. Logs a warning and returns nil
    # instead of raising; #each_event uses this so a full-stream scan skips that
    # one event and keeps going. #fetch_event and #fetch_events still call
    # #decode directly: asking for one specific event or aggregate stream should
    # fail loudly, not silently come back short.
    protected def decode_or_skip(header : JSON::Any, body : JSON::Any) : ES::EventStore::Event?
      decode(header, body)
    rescue ex : ES::Exception::NotFound
      Log.warn { "Skipping event '#{header["event_id"]?}' (handle '#{header["event_handle"]?}'): encryption key destroyed — #{ex.message}" }
      nil
    end
  end
end
