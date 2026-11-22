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
    # Positions are not commit-ordered: two concurrent appends may commit in the
    # opposite order of their positions. A position is therefore no cursor for
    # following the store — reading again `after` the last position seen can
    # miss an event that committed late with a lower one. Use it for what a
    # consistency boundary needs: the position of the last event a decision saw.
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

    # Appends several events atomically — all or none — and, given a condition,
    # only if no event matching its query was appended after its position.
    # Raises `ES::Exception::Conflict` when one was, and appends nothing.
    #
    # This is the write side of a dynamic consistency boundary: read the events
    # a decision depends on, decide, then append on the condition that nothing
    # the decision depended on changed in between. Returns the position of the
    # last appended event.
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

    # An event ready to be stored, with what locking and matching need to know
    protected record EncodedEvent, event : ES::Event, header : String, body : String, handle : String, tags : Array(String)

    # Encodes a batch before anything is written, so a hashing or encryption
    # failure on any one event leaves the store untouched
    protected def encode_events(events : Array(ES::Event)) : Array(EncodedEvent)
      raise ES::Exception::InvalidState.new("Nothing to append: the batch is empty") if events.empty?

      events.map do |event|
        EncodedEvent.new(event, encode_header(event), encode_body(event), event.header.event_handle, stored_tags(event))
      end
    end

    # The error raised when an append condition fails. Names no tag values,
    # which may be personal data.
    protected def append_conflict(condition : ES::AppendCondition) : ES::Exception::Conflict
      ES::Exception::Conflict.new(
        "Append condition failed: an event matching the query was appended after position #{condition.after || "none"}",
        status_code: HTTP::Status::CONFLICT
      )
    end

    # Refuses read options that have no sensible meaning
    protected def validate_read_options(after : Int64?, limit : Int32?)
      raise ES::Exception::InvalidState.new("after must not be negative, got #{after}") if after && after < 0
      raise ES::Exception::InvalidState.new("limit must be at least 1, got #{limit}") if limit && limit < 1
    end

    @encryption : ES::EncryptionKeyManager? = nil
    @tag_hasher : ES::TagHasher? = nil

    struct Event
      getter header : JSON::Any
      getter body : JSON::Any

      # Position of the event in the store's global order, where the read that
      # returned it knows it. Positions only ever increase, but are not gapless.
      getter position : Int64?

      # Whether the body was encrypted under a key that has since been destroyed.
      # The header — type, tags, position — is intact; the body is JSON null.
      getter? body_erased : Bool

      # Initialize Event with header and body
      def initialize(
        @header : JSON::Any,
        @body : JSON::Any,
        @position : Int64? = nil,
        @body_erased : Bool = false,
      )
      end
    end

    # A query item with its tags in stored form, ready to match against headers
    protected record EncodedQueryItem, types : Array(String), tags : Array(String)

    # Encodes the tags of every item of a query the way `encode_header` encodes
    # them on append, so a query for a hashed tag compares digests, never values
    protected def encode_query(query : ES::Query) : Array(EncodedQueryItem)
      query.items.map do |item|
        EncodedQueryItem.new(item.types, item.tags.map { |tag| encode_tag(tag) })
      end
    end

    # Returns the header JSON to persist, carrying the event's tags in their
    # stored form.
    #
    # The tags are derived here rather than when the event is built, because a
    # hashed tag needs the store's hasher. That also means the plaintext value of
    # a hashed tag never sits on a header that could be serialized elsewhere.
    #
    # An event without plaintext tags keeps the header's stored tags as they are,
    # which is what an event read back and appended again carries.
    protected def encode_header(event : ES::Event) : String
      return event.header.to_json if event.tags.empty?

      event.header.with_tags(stored_tags(event)).to_json
    end

    # The tags an event is stored with — the ones `encode_header` writes, and the
    # ones the Postgres store locks. Deriving both here keeps them from drifting
    # apart: a tag stored but not locked would slip past conditional appends.
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
        raise ES::Exception::InvalidState.new("'#{event.class.name}' carries a stored tag '#{key}' that is declared hashed but holds no digest") if hashed && !value.matches?(STORED_DIGEST)
      end

      stored
    end

    # What `ES::TagHasher` stores for a hashed tag's value
    private STORED_DIGEST = /\A[0-9a-f]{#{ES::TagHasher::DIGEST_SIZE * 2}}\z/

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
    protected def decode(header : JSON::Any, body : JSON::Any, position : Int64? = nil) : ES::EventStore::Event
      parsed_header = ES::Event::Header.from_json(header.to_json)
      return ES::EventStore::Event.new(header, body, position) if parsed_header.encryption_key_id.nil?

      encryption = @encryption
      raise ES::Exception::DependencyUnavailable.new("Event body is encrypted but this event store has no encryption configured") if encryption.nil?

      ES::EventStore::Event.new(header, encryption.open(body, parsed_header), position)
    end

    # Same as #decode, but tolerates a body encrypted under a key that has since
    # been destroyed. Only some events in a stream may be encrypted at all —
    # typically the ones carrying PII — so one shredded key must not stop a
    # projector from replaying everything else. Logs a warning and returns nil
    # instead of raising; #each_event uses this so a full-stream scan skips that
    # one event and keeps going. #fetch_event and #fetch_events still call
    # #decode directly: asking for one specific event or aggregate stream should
    # fail loudly, not silently come back short.
    # Same as #decode, but returns an event whose body was encrypted under a
    # destroyed key as header only, flagged `body_erased?`. #read uses this so
    # erasing a subject's data leaves the shape of every stream it appears in
    # intact.
    #
    # The key store raises the same `NotFound` for a key that was destroyed and
    # one that never existed in this environment, so a misconfigured key store
    # also reads as erased here.
    protected def decode_or_erase(header : JSON::Any, body : JSON::Any, position : Int64? = nil) : ES::EventStore::Event
      decode(header, body, position)
    rescue ES::Exception::NotFound
      ES::EventStore::Event.new(header, JSON::Any.new(nil), position, body_erased: true)
    end

    protected def decode_or_skip(header : JSON::Any, body : JSON::Any) : ES::EventStore::Event?
      decode(header, body)
    rescue ex : ES::Exception::NotFound
      Log.warn { "Skipping event '#{header["event_id"]?}' (handle '#{header["event_handle"]?}'): encryption key destroyed — #{ex.message}" }
      nil
    end
  end
end
