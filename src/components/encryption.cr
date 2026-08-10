module ES
  # Envelope encryption for event bodies, with crypto-shredding as the point of it.
  #
  # A data encryption key (DEK) encrypts event bodies. The DEK itself is only ever
  # stored wrapped under an application encryption key (KEK) held in
  # `ES::ApplicationKeyRing`. Destroy the DEK and every body encrypted under it is
  # unreadable for good — which is how an event store, immutable by construction,
  # answers an erasure request. Encryption at rest is the side effect.
  #
  # The key is chosen when the event is constructed, not derived from the event, so
  # one aggregate's events may sit under several keys — events carrying a customer's
  # data can be keyed by that customer even when the aggregate is an order.
  #
  # ```
  # encryption = ES::Encryption.new(key_store, ES::ApplicationKeyRing.from_env)
  # key_id = encryption.create_key
  #
  # store.append(CustomerRegistered.new(
  #   actor_id: actor, command_handler: "RegisterCustomer",
  #   encryption_key_id: key_id, name: "...", iban: "..."
  # ))
  #
  # encryption.destroy_key(key_id) # the body is now gone
  # ```
  class Encryption
    # Marks a body as an envelope rather than plaintext. Its presence is what lets
    # encrypted and plaintext bodies coexist in one store, so encryption can be
    # switched on for new events without rewriting a byte of history.
    ENVELOPE_MARKER = "__es"
    ENVELOPE_FORMAT = 1

    # An unwrapped data key is expensive to obtain — a keystore round trip and, once
    # the key ring is backed by a KMS, a network call. Hydrating one aggregate hits
    # the same key repeatedly, so a cache is not optional. The cost is plaintext key
    # material resident in process memory, bounded by this many entries and evicted
    # oldest-first.
    DEFAULT_CACHE_SIZE = 1024

    @cache : Hash(UUID, Bytes) = Hash(UUID, Bytes).new

    def initialize(
      @key_store : ES::KeyStore,
      @key_ring : ES::ApplicationKeyRing,
      @cache_size : Int32 = DEFAULT_CACHE_SIZE,
    )
    end

    # Creates a new data encryption key, wrapped under the current application key,
    # and returns the id to put on an event header
    def create_key : UUID
      data_key = ES::PayloadCipher.random_key
      application_encryption_key_id, wrapped = @key_ring.wrap(data_key)

      encryption_key_id = @key_store.create(wrapped, application_encryption_key_id, ES::PayloadCipher::ALGORITHM)
      remember(encryption_key_id, data_key)
      encryption_key_id
    end

    # Destroys a data encryption key. Every event body encrypted under it becomes
    # permanently unreadable — this is the erasure, and it does not come back.
    def destroy_key(encryption_key_id : UUID)
      @key_store.destroy(encryption_key_id)
      @cache.delete(encryption_key_id)
    end

    # Whether a key has been destroyed
    def destroyed?(encryption_key_id : UUID) : Bool
      @key_store.fetch(encryption_key_id).destroyed?
    end

    # Returns the body JSON to persist for an event: an envelope when the event
    # names a key, the plain body otherwise.
    def seal(event : ES::Event) : String
      encryption_key_id = event.header.encryption_key_id

      if encryption_key_id.nil?
        raise ES::Exception::InvalidState.new("'#{event.class.name}' is declared encrypted but carries no encryption_key_id") if event.class.encrypted?
        return event.body.to_json
      end

      # The binding travels inside the ciphertext, since the cipher authenticates
      # the payload but knows nothing of the event it belongs to. It makes an
      # envelope useless anywhere but on the exact event it was written for, even
      # to someone holding the key it shares with other events.
      plaintext = String.build do |io|
        io << %({"h":") << binding_digest(event.header) << %(","b":)
        event.body.to_json(io)
        io << "}"
      end

      sealed = ES::PayloadCipher.seal(data_key(encryption_key_id), plaintext.to_slice)

      JSON.build do |json|
        json.object do
          json.field ENVELOPE_MARKER, ENVELOPE_FORMAT
          json.field "alg", ES::PayloadCipher::ALGORITHM
          json.field "kid", encryption_key_id.to_s
          json.field "iv", Base64.strict_encode(sealed.iv)
          json.field "ct", Base64.strict_encode(sealed.ciphertext)
          json.field "tag", Base64.strict_encode(sealed.tag)
        end
      end
    end

    # Returns the plaintext body for a stored one, alongside whether it was shredded.
    #
    # A destroyed key is reported rather than raised, because what to do about it
    # differs by caller: hydrating an aggregate over a hole is a correctness problem,
    # while a projection replay must simply carry on. A key row that is missing
    # altogether is a different matter and does raise — that means the store is
    # pointed at the wrong database, not that anything was erased.
    def open(body : JSON::Any, header : ES::Event::Header) : {JSON::Any, Bool}
      return {body, false} unless self.class.envelope?(body)

      encryption_key_id = header.encryption_key_id
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' has an encrypted body but no encryption_key_id in its header") if encryption_key_id.nil?

      kid = body["kid"]?.try(&.as_s?)
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' envelope names key '#{kid}' but its header names '#{encryption_key_id}'") if kid != encryption_key_id.to_s

      key = @key_store.fetch(encryption_key_id)
      return {JSON::Any.new(Hash(String, JSON::Any).new), true} if key.destroyed?

      sealed = ES::PayloadCipher::Sealed.new(
        decode_field(body, "iv", header),
        decode_field(body, "ct", header),
        decode_field(body, "tag", header),
      )

      plaintext = JSON.parse(String.new(ES::PayloadCipher.open(unwrap(key), sealed)))

      digest = plaintext["h"]?.try(&.as_s?)
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' body was decrypted but is bound to a different event") if digest != binding_digest(header)

      inner = plaintext["b"]?
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' body was decrypted but carries no payload") if inner.nil?

      {inner, false}
    end

    # Re-wraps every live data key under the current application key.
    #
    # This is the whole payoff of holding the DEKs wrapped: rotating the application
    # key touches only this table and leaves every event untouched. Rotating a data
    # key is deliberately not offered — that would mean rewriting the event store.
    def rewrap_all : Int32
      rewrapped = 0
      current = @key_ring.current_id

      @key_store.each_live do |key|
        next if key.application_encryption_key_id == current

        data_key = @key_ring.unwrap(key.application_encryption_key_id, key.material)
        application_encryption_key_id, wrapped = @key_ring.wrap(data_key)

        @key_store.rewrap(key.encryption_key_id, wrapped, application_encryption_key_id)
        rewrapped += 1
      end

      rewrapped
    end

    # Whether a stored body is an envelope rather than plaintext
    def self.envelope?(body : JSON::Any) : Bool
      !!body.as_h?.try(&.has_key?(ENVELOPE_MARKER))
    end

    # Binds a ciphertext to the one event it belongs to, so an envelope cannot be
    # moved to another row even by someone holding the key
    private def binding_digest(header : ES::Event::Header) : String
      Digest::SHA256.hexdigest("#{header.event_id}|#{header.aggregate_id}|#{header.aggregate_version}|#{header.event_handle}")
    end

    private def decode_field(body : JSON::Any, field : String, header : ES::Event::Header) : Bytes
      value = body[field]?.try(&.as_s?)
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' envelope is missing field '#{field}'") if value.nil?
      Base64.decode(value)
    rescue Base64::Error
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' envelope field '#{field}' is not valid base64")
    end

    private def data_key(encryption_key_id : UUID) : Bytes
      cached = @cache[encryption_key_id]?
      return cached unless cached.nil?

      unwrap(@key_store.fetch(encryption_key_id))
    end

    private def unwrap(key : ES::KeyStore::Key) : Bytes
      cached = @cache[key.encryption_key_id]?
      return cached unless cached.nil?

      data_key = @key_ring.unwrap(key.application_encryption_key_id, key.material)
      remember(key.encryption_key_id, data_key)
      data_key
    end

    private def remember(encryption_key_id : UUID, data_key : Bytes)
      return if @cache_size <= 0

      while @cache.size >= @cache_size
        @cache.shift?
      end

      @cache[encryption_key_id] = data_key
    end
  end
end
