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
    # store.encryption_key_ids(aggregate_id).each { |id| encryption.destroy_key(id) }
    # ```
    #
    # A subject whose data spans several aggregates is the application's to map — it
    # holds the key id on its own record and calls `destroy_key` directly.
    abstract def encryption_key_ids(aggregate_id : UUID) : Array(UUID)

    @encryption : ES::Encryption? = nil

    struct Event
      getter header : JSON::Any
      getter body : JSON::Any

      # Whether this event's key was destroyed, making the body permanently
      # unreadable. The body is then empty.
      #
      # Reported rather than raised because the right response differs by caller:
      # `ES::Aggregate#hydrate` treats a hole in its stream as a correctness problem,
      # while `ES::Projection#replay` must stay able to rebuild after an erasure.
      getter? shredded : Bool

      # Initialize Event with header and body
      def initialize(
        @header : JSON::Any,
        @body : JSON::Any,
        @shredded : Bool = false,
      )
      end
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

    # Turns a stored row into an event, decrypting the body when it is an envelope.
    # A store always hands back plaintext, so nothing downstream has to know that
    # encryption exists.
    protected def decode(header : JSON::Any, body : JSON::Any) : ES::EventStore::Event
      return ES::EventStore::Event.new(header, body) unless ES::Encryption.envelope?(body)

      encryption = @encryption
      raise ES::Exception::DependencyUnavailable.new("Event body is encrypted but this event store has no encryption configured") if encryption.nil?

      plaintext, shredded = encryption.open(body, ES::Event::Header.from_json(header.to_json))
      ES::EventStore::Event.new(header, plaintext, shredded)
    end
  end
end
