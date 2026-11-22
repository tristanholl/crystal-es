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

    # Prefix of every label `derive_key` derives under
    DERIVATION_PREFIX = "crystal-es:derive:"

    # Derives an independent key for another purpose, such as `ES::TagHasher`, so
    # the application still manages exactly one secret.
    #
    # Every label is prefixed with `DERIVATION_PREFIX`, which none of the labels
    # `ES::PayloadCipher` derives its key-wrapping subkeys under starts with. No
    # label passed here can therefore yield a key that wraps data encryption keys,
    # and that stays true if the cipher gains another subkey.
    def derive_key(label : String) : Bytes
      OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, @key, DERIVATION_PREFIX + label)
    end

    # Keeps the key out of logs and error reports
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << " key_id=" << @key_id << ">"
    end

    # :ditto:
    def to_s(io : IO) : Nil
      inspect(io)
    end
  end
end
