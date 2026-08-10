module ES
  module KeyStoreAdapters
    class InMemory < ES::KeyStore
      @keys : Hash(UUID, ES::KeyStore::Key) = Hash(UUID, ES::KeyStore::Key).new

      def initialize
      end

      # Nothing to prepare
      def setup
        # Noop
      end

      # Stores a wrapped key and returns its id
      def create(
        encrypted_encryption_key : Bytes,
        application_encryption_key_id : String,
        algorithm : String = ES::PayloadCipher::ALGORITHM,
      ) : UUID
        id = UUID.v7
        @keys[id] = ES::KeyStore::Key.new(
          encryption_key_id: id,
          encrypted_encryption_key: encrypted_encryption_key,
          application_encryption_key_id: application_encryption_key_id,
          algorithm: algorithm,
        )
        id
      end

      # Returns a key row, destroyed or not
      def fetch(encryption_key_id : UUID) : ES::KeyStore::Key
        key = @keys.fetch(encryption_key_id, nil)
        raise ES::Exception::NotFound.new("Encryption key '#{encryption_key_id}' not found in keystore") if key.nil?
        key
      end

      # Destroys the key material, keeping the row as a tombstone
      def destroy(encryption_key_id : UUID)
        key = fetch(encryption_key_id)
        return if key.destroyed?

        @keys[encryption_key_id] = ES::KeyStore::Key.new(
          encryption_key_id: key.encryption_key_id,
          encrypted_encryption_key: nil,
          application_encryption_key_id: key.application_encryption_key_id,
          algorithm: key.algorithm,
          created_at: key.created_at,
          destroyed_at: Time.utc,
        )
      end

      # Yields every key that has not been destroyed
      def each_live(&block : ES::KeyStore::Key ->)
        @keys.each_value do |key|
          block.call(key) unless key.destroyed?
        end
      end

      # Replaces the wrapping of a live key, used by application key rotation
      def rewrap(encryption_key_id : UUID, encrypted_encryption_key : Bytes, application_encryption_key_id : String)
        key = fetch(encryption_key_id)
        raise ES::Exception::KeyDestroyed.new("Encryption key '#{encryption_key_id}' was destroyed and cannot be rewrapped") if key.destroyed?

        @keys[encryption_key_id] = ES::KeyStore::Key.new(
          encryption_key_id: key.encryption_key_id,
          encrypted_encryption_key: encrypted_encryption_key,
          application_encryption_key_id: application_encryption_key_id,
          algorithm: key.algorithm,
          created_at: key.created_at,
        )
      end
    end
  end
end
