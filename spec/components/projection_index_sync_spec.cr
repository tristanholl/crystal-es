require "../spec_helper"
require "pg"

# Index drift is applied to an existing projection table on boot. These specs
# need a live Postgres and only run when ES_TEST_DATABASE_URL is set, e.g.
#   ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec

# Every version writes to the same table. Metadata is keyed by class name, so a
# "previous deploy" is simulated by recording an older version's definition
# under the class being booted (see `record_previous`).
class IndexSyncV1 < ES::Projection
  include ES::ProjectionDSL

  define_projection "index_sync.items" do
    column :id, Int32, primary_key: true
    column :name, String
    column :amount, Int64

    index [:name]
  end

  apply DummyEvent do
    nil
  end
end

# v1 + an extra unique index
class IndexSyncV2 < ES::Projection
  include ES::ProjectionDSL

  define_projection "index_sync.items" do
    column :id, Int32, primary_key: true
    column :name, String
    column :amount, Int64

    index [:name]
    index [:amount], unique: true, name: "items_amount_uidx"
  end

  apply DummyEvent do
    nil
  end
end

# v2 with items_name_idx removed
class IndexSyncV3 < ES::Projection
  include ES::ProjectionDSL

  define_projection "index_sync.items" do
    column :id, Int32, primary_key: true
    column :name, String
    column :amount, Int64

    index [:amount], unique: true, name: "items_amount_uidx"
  end

  apply DummyEvent do
    nil
  end
end

# v2 with items_amount_uidx now non-unique over (amount, name)
class IndexSyncV4 < ES::Projection
  include ES::ProjectionDSL

  define_projection "index_sync.items" do
    column :id, Int32, primary_key: true
    column :name, String
    column :amount, Int64

    index [:name]
    index [:amount, :name], name: "items_amount_uidx"
  end

  apply DummyEvent do
    nil
  end
end

# v1 + a unique index over a column that holds duplicates in the spec
class IndexSyncUniqueName < ES::Projection
  include ES::ProjectionDSL

  define_projection "index_sync.items" do
    column :id, Int32, primary_key: true
    column :name, String
    column :amount, Int64

    index [:name]
    index [:name], unique: true, name: "items_name_uidx"
  end

  apply DummyEvent do
    nil
  end
end

module IndexSyncSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?
  @@db : DB::Database?

  def self.db : DB::Database
    @@db ||= DB.open(URL.not_nil!)
  end

  def self.reset : Nil
    db.exec %(DROP SCHEMA IF EXISTS "index_sync" CASCADE)
    db.exec %(CREATE SCHEMA "index_sync")
  end

  def self.boot(klass) : Nil
    klass.new(
      event_handlers: ES::EventHandlers.new,
      event_store: ES::EventStoreAdapters::InMemory.new,
      projection_database: db,
    ).setup
  end

  # Records `previous`'s definition under `current`'s class name, as if
  # `current` had been deployed before with `previous`'s schema.
  def self.record_previous(current, previous) : Nil
    db.exec %(DELETE FROM "index_sync"."#{ES::ProjectionMeta::META_TABLE}")
    ES::ProjectionMeta.new(db, "index_sync").upsert(
      current.name, current.table, previous.compiled_fingerprint, previous.compiled_definition
    )
  end

  def self.indexes : Hash(String, String)
    result = {} of String => String
    db.query_each(%(SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'index_sync' AND tablename = 'items')) do |rs|
      result[rs.read(String)] = rs.read(String)
    end
    result
  end

  def self.stored_fingerprint(klass) : String?
    ES::ProjectionMeta.new(db, "index_sync").fetch(klass.name).try(&.fingerprint)
  end
end

describe "ES::ProjectionDSL index sync" do
  if IndexSyncSpec::URL.nil?
    pending "applies index drift to existing tables (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  else
    before_each { IndexSyncSpec.reset }

    it "creates declared indexes with the table" do
      IndexSyncSpec.boot(IndexSyncV2)

      idx = IndexSyncSpec.indexes
      idx.keys.should contain("items_name_idx")
      idx["items_amount_uidx"].should contain("UNIQUE")
    end

    it "creates an index added to an existing projection" do
      IndexSyncSpec.boot(IndexSyncV1)
      IndexSyncSpec.indexes.keys.should_not contain("items_amount_uidx")

      IndexSyncSpec.record_previous(IndexSyncV2, IndexSyncV1)
      IndexSyncSpec.boot(IndexSyncV2)

      IndexSyncSpec.indexes["items_amount_uidx"].should contain("UNIQUE")
      IndexSyncSpec.stored_fingerprint(IndexSyncV2).should eq(IndexSyncV2.compiled_fingerprint)
    end

    it "drops an index removed from the projection" do
      IndexSyncSpec.boot(IndexSyncV2)
      IndexSyncSpec.record_previous(IndexSyncV3, IndexSyncV2)
      IndexSyncSpec.boot(IndexSyncV3)

      idx = IndexSyncSpec.indexes
      idx.keys.should_not contain("items_name_idx")
      idx.keys.should contain("items_amount_uidx")
    end

    it "recreates an index whose columns or uniqueness changed" do
      IndexSyncSpec.boot(IndexSyncV2)
      IndexSyncSpec.record_previous(IndexSyncV4, IndexSyncV2)
      IndexSyncSpec.boot(IndexSyncV4)

      definition = IndexSyncSpec.indexes["items_amount_uidx"]
      definition.should_not contain("UNIQUE")
      definition.should contain("(amount, name)")
    end

    it "recreates an index the metadata claims but the table lacks" do
      IndexSyncSpec.boot(IndexSyncV2)
      IndexSyncSpec.db.exec %(DROP INDEX "index_sync".items_amount_uidx)

      IndexSyncSpec.boot(IndexSyncV2)

      IndexSyncSpec.indexes.keys.should contain("items_amount_uidx")
    end

    it "raises and keeps the stored fingerprint when an index cannot be built" do
      IndexSyncSpec.boot(IndexSyncV1)
      IndexSyncSpec.db.exec %(INSERT INTO "index_sync"."items" (id, name, amount) VALUES (1, 'dup', 1), (2, 'dup', 2))
      IndexSyncSpec.record_previous(IndexSyncUniqueName, IndexSyncV1)

      expect_raises(Exception) { IndexSyncSpec.boot(IndexSyncUniqueName) }

      IndexSyncSpec.indexes.keys.should_not contain("items_name_uidx")
      IndexSyncSpec.stored_fingerprint(IndexSyncUniqueName).should eq(IndexSyncV1.compiled_fingerprint)
    end

    it "rolls back drops when a create in the same sync fails" do
      IndexSyncSpec.boot(IndexSyncV2)
      IndexSyncSpec.db.exec %(INSERT INTO "index_sync"."items" (id, name, amount) VALUES (1, 'dup', 1), (2, 'dup', 2))
      # Removing items_amount_uidx while adding a unique index that cannot be built.
      IndexSyncSpec.record_previous(IndexSyncUniqueName, IndexSyncV2)

      expect_raises(Exception) { IndexSyncSpec.boot(IndexSyncUniqueName) }

      IndexSyncSpec.indexes.keys.should contain("items_amount_uidx")
    end
  end
end
