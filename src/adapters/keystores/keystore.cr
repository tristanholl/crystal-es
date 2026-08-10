module ES
  # Persistence for wrapped data encryption keys.
  #
  # Deliberately not event sourced: the whole point is that a key can be destroyed,
  # which an append-only log cannot do.
  #
  # The table holds no reference to any business entity. References run one way
  # only — an event header points at a key — so domain identifiers, which are
  # frequently personal data themselves, never accumulate next to the keys. The
  # reverse lookup needed at erasure time is answered by
  # `ES::EventStore#encryption_key_ids` or by the application's own records.
  abstract class KeyStore
    abstract def setup
    abstract def create(encrypted_encryption_key : Bytes, application_encryption_key_id : String, algorithm : String) : UUID
    abstract def fetch(encryption_key_id : UUID) : ES::KeyStore::Key
    abstract def destroy(encryption_key_id : UUID)
    abstract def each_live(&block : ES::KeyStore::Key ->)
    abstract def rewrap(encryption_key_id : UUID, encrypted_encryption_key : Bytes, application_encryption_key_id : String)

    # A row of the key table.
    #
    # A destroyed key keeps its row with `encrypted_encryption_key` nulled. Keeping
    # the tombstone is what lets a reader tell "deliberately destroyed" — the
    # expected end of an erasure request — from "row missing entirely", which means
    # the store is pointed at the wrong database. Deleting the row collapses those
    # two very different situations into one.
    struct Key
      getter encryption_key_id : UUID
      getter encrypted_encryption_key : Bytes?
      getter application_encryption_key_id : String
      getter algorithm : String
      getter created_at : Time
      getter destroyed_at : Time?

      def initialize(
        @encryption_key_id : UUID,
        @encrypted_encryption_key : Bytes?,
        @application_encryption_key_id : String,
        @algorithm : String = ES::PayloadCipher::ALGORITHM,
        @created_at : Time = Time.utc,
        @destroyed_at : Time? = nil,
      )
      end

      # Whether the key was destroyed, making every body under it unreadable
      def destroyed? : Bool
        !@destroyed_at.nil?
      end

      # The wrapped key material, raising when the key has been destroyed
      def material : Bytes
        m = @encrypted_encryption_key
        raise ES::Exception::KeyDestroyed.new("Encryption key '#{@encryption_key_id}' was destroyed") if m.nil?
        m
      end
    end
  end
end
