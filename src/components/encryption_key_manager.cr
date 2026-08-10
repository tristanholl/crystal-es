module ES
  # Envelope encryption for event bodies, with crypto-shredding as the point of it.
  #
  # A data encryption key (DEK) encrypts event bodies. The DEK itself is only ever
  # stored wrapped under the application encryption key held in
  # `ES::ApplicationEncryptionKeyManager`. Destroy the DEK's row and every body
  # encrypted under it is unreadable for good — reading one raises the same
  # `ES::Exception::NotFound` as any other missing row. That is how an event store,
  # immutable by construction, answers an erasure request. Encryption at rest is
  # the side effect.
  #
  # The key is chosen when the event is constructed, not derived from the event, so
  # one aggregate's events may sit under several keys — events carrying a customer's
  # data can be keyed by that customer even when the aggregate is an order.
  #
  # ```
  # application_key = ES::ApplicationEncryptionKeyManager.new(Base64.decode(ENV["APPLICATION_ENCRYPTION_KEYS"]))
  # key_manager = ES::EncryptionKeyManager.new(key_store, application_key)
  # key_id = key_manager.create_key
  #
  # store.append(CustomerRegistered.new(
  #   actor_id: actor, command_handler: "RegisterCustomer",
  #   encryption_key_id: key_id, name: "...", iban: "..."
  # ))
  #
  # key_manager.destroy_key(key_id) # the body is now gone
  # ```
  class EncryptionKeyManager
    def initialize(
      @key_store : ES::KeyStore,
      @application_key : ES::ApplicationEncryptionKeyManager,
    )
    end

    # Creates a new data encryption key, wrapped under the application key, and
    # returns the id to put on an event header
    def create_key : UUID
      data_key = ES::PayloadCipher.random_key
      wrapped = @application_key.wrap(data_key)

      @key_store.create(wrapped, @application_key.key_id, ES::PayloadCipher::ALGORITHM)
    end

    # Destroys a data encryption key. Every event body encrypted under it becomes
    # permanently unreadable — this is the erasure, and it does not come back.
    def destroy_key(encryption_key_id : UUID)
      @key_store.destroy(encryption_key_id)
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

      key = @key_store.fetch(encryption_key_id)
      sealed = ES::PayloadCipher.seal(@application_key.unwrap(key.application_encryption_key_id, key.encryption_private_key), plaintext.to_slice)

      JSON.build do |json|
        json.object do
          json.field "iv", Base64.strict_encode(sealed.iv)
          json.field "ct", Base64.strict_encode(sealed.ciphertext)
          json.field "tag", Base64.strict_encode(sealed.tag)
        end
      end
    end

    # Returns the plaintext body for a stored one.
    #
    # A destroyed key has no row left, so `KeyStore#fetch` raises `NotFound` and
    # that propagates as-is — the same exception any other missing row would raise.
    # There is no separate "shredded" signal: the deletion is the answer.
    def open(body : JSON::Any, header : ES::Event::Header) : JSON::Any
      encryption_key_id = header.encryption_key_id
      return body if encryption_key_id.nil?

      key = @key_store.fetch(encryption_key_id)

      sealed = ES::PayloadCipher::Sealed.new(
        decode_field(body, "iv", header),
        decode_field(body, "ct", header),
        decode_field(body, "tag", header),
      )

      plaintext = JSON.parse(String.new(ES::PayloadCipher.open(@application_key.unwrap(key.application_encryption_key_id, key.encryption_private_key), sealed)))

      digest = plaintext["h"]?.try(&.as_s?)
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' body was decrypted but is bound to a different event") if digest != binding_digest(header)

      inner = plaintext["b"]?
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' body was decrypted but carries no payload") if inner.nil?

      inner
    end

    # Binds a ciphertext to the one event — and the one key — it belongs to, so an
    # envelope cannot be moved to another row, nor opened under a header naming a
    # different key, even by someone holding both keys.
    private def binding_digest(header : ES::Event::Header) : String
      Digest::SHA256.hexdigest("#{header.encryption_key_id}|#{header.event_id}|#{header.aggregate_id}|#{header.aggregate_version}|#{header.event_handle}")
    end

    private def decode_field(body : JSON::Any, field : String, header : ES::Event::Header) : Bytes
      value = body[field]?.try(&.as_s?)
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' envelope is missing field '#{field}'") if value.nil?
      Base64.decode(value)
    rescue Base64::Error
      raise ES::Exception::InvalidEventStream.new("Event '#{header.event_id}' envelope field '#{field}' is not valid base64")
    end
  end
end
