module ES
  # Persistence for wrapped data encryption keys.
  #
  # Deliberately not event sourced: the whole point is that a key can be destroyed,
  # which an append-only log cannot do. Destroying a key is a real delete — the row
  # is gone, and reading a body that names it raises the same `NotFound` any
  # missing row would.
  #
  # The table holds no reference to any business entity. References run one way
  # only — an event header points at a key — so domain identifiers, which are
  # frequently personal data themselves, never accumulate next to the keys. The
  # reverse lookup needed at erasure time is answered by
  # `ES::EventStore#encryption_key_ids` or by the application's own records.
  abstract class KeyStore
    abstract def setup
    abstract def create(encryption_private_key : Bytes, application_encryption_key_id : String, encryption_algorithm : String) : UUID
    abstract def fetch(id : UUID) : ES::KeyStore::Key
    abstract def destroy(id : UUID)

    # A row of the key table
    struct Key
      getter id : UUID
      getter encryption_private_key : Bytes
      getter application_encryption_key_id : String
      getter encryption_algorithm : String
      getter created_at : Time

      def initialize(
        @id : UUID,
        @encryption_private_key : Bytes,
        @application_encryption_key_id : String,
        @encryption_algorithm : String = ES::PayloadCipher::ALGORITHM,
        @created_at : Time = Time.utc,
      )
      end
    end
  end
end
