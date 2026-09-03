module ES
  module KeyStoreAdapters
    class Postgres < ES::KeyStore
      # Initialize with a database connection
      def initialize(@db : DB::Database)
      end

      # Initializes the database with the necessary schema and table for the keystore
      def setup
        skip = @db.query_one %(SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname = 'eventstore' AND tablename = 'encryption_keys');), as: Bool
        return true if skip

        migrations = Array(String).new
        migrations << %( CREATE SCHEMA IF NOT EXISTS "eventstore"; )
        migrations << %(
          CREATE TABLE "eventstore"."encryption_keys" (
            "id"                             UUID PRIMARY KEY,
            "encryption_private_key"         BYTEA       NOT NULL,
            "encryption_algorithm"           TEXT        NOT NULL DEFAULT '#{ES::PayloadCipher::ALGORITHM}',
            "application_encryption_key_id"  TEXT        NOT NULL,
            "created_at"                     TIMESTAMPTZ NOT NULL DEFAULT now()
          );
        )

        # The key material must never reach a monitoring role, so the blanket
        # SELECT grants the eventstore hands to pg_monitor are deliberately not
        # extended to this table.

        migrations.each { |statement| @db.exec statement }
      end

      # Stores a wrapped key and returns its id
      def create(
        encryption_private_key : Bytes,
        application_encryption_key_id : String,
        encryption_algorithm : String = ES::PayloadCipher::ALGORITHM,
      ) : UUID
        id = UUID.v7
        @db.exec(
          %(INSERT INTO "eventstore"."encryption_keys" (id, encryption_private_key, application_encryption_key_id, encryption_algorithm) VALUES ($1, $2, $3, $4)),
          id, encryption_private_key, application_encryption_key_id, encryption_algorithm
        )
        id
      end

      # Returns a key row
      def fetch(id : UUID) : ES::KeyStore::Key
        encryption_private_key, application_encryption_key_id, encryption_algorithm, created_at = @db.query_one(
          %(SELECT encryption_private_key, application_encryption_key_id, encryption_algorithm, created_at FROM "eventstore"."encryption_keys" WHERE id = $1),
          id, as: {Bytes, String, String, Time}
        )

        ES::KeyStore::Key.new(
          id: id,
          encryption_private_key: encryption_private_key,
          application_encryption_key_id: application_encryption_key_id,
          encryption_algorithm: encryption_algorithm,
          created_at: created_at,
        )
      rescue DB::NoResultsError
        raise ES::Exception::NotFound.new("Encryption key '#{id}' not found in keystore")
      end

      # Deletes the key. This is the erasure: once committed, the bodies encrypted
      # under this key are unreadable for good — there is no recovery path.
      def destroy(id : UUID)
        @db.exec(%(DELETE FROM "eventstore"."encryption_keys" WHERE id = $1), id)
      end
    end
  end
end
