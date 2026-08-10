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

        m = Array(String).new
        m << %( CREATE SCHEMA IF NOT EXISTS "eventstore"; )
        m << %(
          CREATE TABLE "eventstore"."encryption_keys" (
            "encryption_key_id"             UUID PRIMARY KEY,
            "encrypted_encryption_key"      BYTEA,
            "application_encryption_key_id" TEXT        NOT NULL,
            "algorithm"                     TEXT        NOT NULL DEFAULT '#{ES::PayloadCipher::ALGORITHM}',
            "created_at"                    TIMESTAMPTZ NOT NULL DEFAULT now(),
            "rewrapped_at"                  TIMESTAMPTZ,
            "destroyed_at"                  TIMESTAMPTZ
          );
        )

        # Rotation re-wraps every live key held under one application key, so that
        # is the access path worth indexing.
        m << %(
          CREATE INDEX encryption_keys_application_key_idx
            ON "eventstore"."encryption_keys" ("application_encryption_key_id")
            WHERE "destroyed_at" IS NULL;
        )

        # The key material must never reach a monitoring role, so the blanket
        # SELECT grants the eventstore hands to pg_monitor are deliberately not
        # extended to this table.

        m.each { |s| @db.exec s }
      end

      # Stores a wrapped key and returns its id
      def create(
        encrypted_encryption_key : Bytes,
        application_encryption_key_id : String,
        algorithm : String = ES::PayloadCipher::ALGORITHM,
      ) : UUID
        id = UUID.v7
        @db.exec(
          %(INSERT INTO "eventstore"."encryption_keys" (encryption_key_id, encrypted_encryption_key, application_encryption_key_id, algorithm) VALUES ($1, $2, $3, $4)),
          id, encrypted_encryption_key, application_encryption_key_id, algorithm
        )
        id
      end

      # Returns a key row, destroyed or not
      def fetch(encryption_key_id : UUID) : ES::KeyStore::Key
        material, application_encryption_key_id, algorithm, created_at, destroyed_at = @db.query_one(
          %(SELECT encrypted_encryption_key, application_encryption_key_id, algorithm, created_at, destroyed_at FROM "eventstore"."encryption_keys" WHERE encryption_key_id = $1),
          encryption_key_id, as: {Bytes?, String, String, Time, Time?}
        )

        ES::KeyStore::Key.new(
          encryption_key_id: encryption_key_id,
          encrypted_encryption_key: material,
          application_encryption_key_id: application_encryption_key_id,
          algorithm: algorithm,
          created_at: created_at,
          destroyed_at: destroyed_at,
        )
      rescue DB::NoResultsError
        raise ES::Exception::NotFound.new("Encryption key '#{encryption_key_id}' not found in keystore")
      end

      # Destroys the key material, keeping the row as a tombstone.
      #
      # This is the erasure. Once committed the bodies encrypted under this key are
      # unreadable for good — there is no recovery path, by design.
      def destroy(encryption_key_id : UUID)
        fetch(encryption_key_id)

        @db.exec(
          %(UPDATE "eventstore"."encryption_keys" SET encrypted_encryption_key = NULL, destroyed_at = COALESCE(destroyed_at, now()) WHERE encryption_key_id = $1),
          encryption_key_id
        )
      end

      # Yields every key that has not been destroyed
      def each_live(&block : ES::KeyStore::Key ->)
        @db.query_all(
          %(SELECT encryption_key_id, encrypted_encryption_key, application_encryption_key_id, algorithm, created_at FROM "eventstore"."encryption_keys" WHERE destroyed_at IS NULL ORDER BY created_at ASC),
          as: {UUID, Bytes, String, String, Time}
        ).each do |id, material, application_encryption_key_id, algorithm, created_at|
          block.call(ES::KeyStore::Key.new(
            encryption_key_id: id,
            encrypted_encryption_key: material,
            application_encryption_key_id: application_encryption_key_id,
            algorithm: algorithm,
            created_at: created_at,
          ))
        end
      end

      # Replaces the wrapping of a live key, used by application key rotation.
      # A destroyed key is left alone — the WHERE clause makes that a no-op rather
      # than resurrecting a tombstone with fresh material.
      def rewrap(encryption_key_id : UUID, encrypted_encryption_key : Bytes, application_encryption_key_id : String)
        @db.exec(
          %(UPDATE "eventstore"."encryption_keys" SET encrypted_encryption_key = $2, application_encryption_key_id = $3, rewrapped_at = now() WHERE encryption_key_id = $1 AND destroyed_at IS NULL),
          encryption_key_id, encrypted_encryption_key, application_encryption_key_id
        )
      end
    end
  end
end
