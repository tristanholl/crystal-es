module ES
  # Holds the application encryption key — the one secret the application manages
  # directly. It is the key encryption key (KEK): it never touches an event body,
  # only the data encryption keys in `ES::KeyStore`, each wrapped under it.
  #
  # A library has no business reaching into the environment itself — that decision
  # (an env var, a mounted secret, a KMS call) belongs to the application. This
  # class only ever receives the key material through its constructor:
  #
  # ```
  # ES::ApplicationEncryptionKeyManager.new(Base64.decode(ENV["APPLICATION_ENCRYPTION_KEY"]))
  # ```
  #
  # `key_id` — stored as `application_encryption_key_id` on each key row — is a
  # SHA-256 digest of the key's own bytes rather than an operator-assigned name.
  # That keeps it always correct for whatever key is actually loaded: a key row
  # wrapped under a different key on a misconfigured environment fails on the id
  # mismatch in `unwrap`, rather than decrypting into garbage.
  class ApplicationEncryptionKeyManager
    # SHA-256 hex digest of the key's own bytes
    getter key_id : String

    def initialize(@key : Bytes)
      raise ES::Exception::InvalidState.new("Application encryption key must be #{ES::PayloadCipher::KEY_SIZE} bytes, got #{@key.size}") if @key.size != ES::PayloadCipher::KEY_SIZE

      @key_id = Digest::SHA256.hexdigest(@key)
    end

    # Wraps a data encryption key under the application key
    def wrap(data_key : Bytes) : Bytes
      ES::PayloadCipher.pack(ES::PayloadCipher.seal(@key, data_key))
    end

    # Unwraps a data encryption key.
    #
    # A mismatched id is a configuration fault, not a missing key — the data is
    # still there, wrapped under a key this environment does not hold.
    def unwrap(application_encryption_key_id : String, wrapped : Bytes) : Bytes
      raise ES::Exception::DependencyUnavailable.new("Key was wrapped under application key '#{application_encryption_key_id}' but this environment holds '#{@key_id}'") if application_encryption_key_id != @key_id

      ES::PayloadCipher.open(@key, ES::PayloadCipher.unpack(wrapped))
    end
  end
end
