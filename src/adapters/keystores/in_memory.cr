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
        encryption_private_key : Bytes,
        application_encryption_key_id : String,
        encryption_algorithm : String = ES::PayloadCipher::ALGORITHM,
      ) : UUID
        id = UUID.v7
        @keys[id] = ES::KeyStore::Key.new(
          id: id,
          encryption_private_key: encryption_private_key,
          application_encryption_key_id: application_encryption_key_id,
          encryption_algorithm: encryption_algorithm,
        )
        id
      end

      # Returns a key row
      def fetch(id : UUID) : ES::KeyStore::Key
        key = @keys.fetch(id, nil)
        raise ES::Exception::NotFound.new("Encryption key '#{id}' not found in keystore") if key.nil?
        key
      end

      # Deletes the key. Bodies encrypted under it become unreadable — a read
      # against a destroyed key raises the same NotFound a missing row always would.
      def destroy(id : UUID)
        @keys.delete(id)
      end
    end
  end
end
