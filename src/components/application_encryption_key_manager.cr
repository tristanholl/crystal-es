module ES
  # Holds the application encryption key — the one secret the application manages
  # directly. It is the key encryption key (KEK): it never touches an event body,
  # only the data encryption keys in `ES::KeyStore`, each wrapped under it.
  #
  # Read once from the environment as raw base64:
  #
  # ```
  # APPLICATION_ENCRYPTION_KEYS = "<base64 32 bytes>"
  # ```
  #
  # `key_id` — stored as `application_encryption_key_id` on each key row — is a
  # SHA-256 digest of the key's own bytes rather than an operator-assigned name.
  # That keeps it always correct for whatever key is actually loaded: a key row
  # wrapped under a different key on a misconfigured environment fails on the id
  # mismatch in `unwrap`, rather than decrypting into garbage.
  class ApplicationEncryptionKeyManager
    ENV_VARIABLE = "APPLICATION_ENCRYPTION_KEYS"

    # SHA-256 hex digest of the key's own bytes
    getter key_id : String

    def initialize(@key : Bytes)
      raise ES::Exception::InvalidState.new("Application encryption key must be #{ES::PayloadCipher::KEY_SIZE} bytes, got #{@key.size}") if @key.size != ES::PayloadCipher::KEY_SIZE

      @key_id = Digest::SHA256.hexdigest(@key)
    end

    # Builds the manager from the environment
    def self.from_env(variable : String = ENV_VARIABLE) : ApplicationEncryptionKeyManager
      raw = ENV[variable]?
      raise ES::Exception::DependencyUnavailable.new("Environment variable '#{variable}' is not set") if raw.nil? || raw.strip.empty?

      key = begin
        Base64.decode(raw.strip)
      rescue
        raise ES::Exception::InvalidState.new("Environment variable '#{variable}' is not valid base64")
      end

      new(key)
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
