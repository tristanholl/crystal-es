module ES
  # The position of each projection subscription, kept in the projection's own
  # database next to its table, so a batch of rows and the position after it
  # commit together. That is what makes a projection apply every event exactly
  # once, even when the projection database isn't the event store's.
  #
  # One table per schema, `"<schema>"."_crystal_es_projection_checkpoints"`,
  # beside `_crystal_es_projection_metadata`. The schema must exist.
  class ProjectionCheckpoints
    TABLE = "_crystal_es_projection_checkpoints"

    def initialize(@db : DB::Database, @schema : String)
      raise ES::Exception::InvalidState.new("Invalid projection schema name '#{@schema}'") unless @schema.matches?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) && @schema.downcase != "eventstore"
    end

    getter db : DB::Database
    getter schema : String

    def setup : Nil
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS "#{@schema}"."#{TABLE}" (
          "name" TEXT PRIMARY KEY,
          "position_transaction_id" BIGINT NOT NULL,
          "position_id" BIGINT NOT NULL,
          "updated_at" TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        SQL
    end

    # The position of a projection subscription, nil if it has none yet
    def fetch(name : String) : ES::EventStore::LogPosition?
      row = @db.query_one?(
        %(SELECT position_transaction_id, position_id FROM "#{@schema}"."#{TABLE}" WHERE name = $1),
        name, as: {Int64, Int64}
      )
      row ? ES::EventStore::LogPosition.new(row[0], row[1]) : nil
    end

    # Records a position unless the subscription has one already
    def create(connection : DB::Database | DB::Connection, name : String, position : ES::EventStore::LogPosition) : Nil
      connection.exec(
        %(INSERT INTO "#{@schema}"."#{TABLE}" (name, position_transaction_id, position_id) VALUES ($1, $2, $3) ON CONFLICT (name) DO NOTHING),
        name, position.transaction_id, position.id
      )
    end

    # Moves a subscription from `expected` to `position` on `connection`, as
    # part of whatever transaction runs there. Raises
    # `ES::Exception::StaleCheckpoint` if it was moved meanwhile.
    def advance(connection : DB::Database | DB::Connection, name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition) : Nil
      result = connection.exec(
        %(UPDATE "#{@schema}"."#{TABLE}" SET position_transaction_id = $4, position_id = $5, updated_at = now() WHERE name = $1 AND position_transaction_id = $2 AND position_id = $3),
        name, expected.transaction_id, expected.id, position.transaction_id, position.id
      )
      raise ES::Exception::StaleCheckpoint.new("Projection subscription '#{name}' is no longer at #{expected}") unless result.rows_affected == 1
    end

    # Puts a subscription at `position`, whatever it was at
    def reset(connection : DB::Database | DB::Connection, name : String, position : ES::EventStore::LogPosition) : Nil
      connection.exec(
        %(INSERT INTO "#{@schema}"."#{TABLE}" (name, position_transaction_id, position_id) VALUES ($1, $2, $3) ON CONFLICT (name) DO UPDATE SET position_transaction_id = EXCLUDED.position_transaction_id, position_id = EXCLUDED.position_id, updated_at = now()),
        name, position.transaction_id, position.id
      )
    end
  end
end
