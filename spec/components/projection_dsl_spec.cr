require "../spec_helper"

class ProjectionDSLTest < ES::Projection
  include ES::ProjectionDSL

  define_projection "test.postings" do
    column :id, Int32, serial: true, primary_key: true
    column :name, String, null: false
    column :amount, Int64, null: false
    column :comment, String, null: true
    column :score, Float64, null: true
    column :active, Bool, null: false, default: true
    column :created_at, Time, null: false

    index [:name], unique: false
    index [:name, :amount], unique: true, name: "postings_name_amount_uidx"
  end
end

class ProjectionDSLTestV2 < ES::Projection
  include ES::ProjectionDSL

  # Same as ProjectionDSLTest but with an extra column — simulates a schema change
  define_projection "test.postings_v2" do
    column :id, Int32, serial: true, primary_key: true
    column :name, String, null: false
    column :amount, Int64, null: false
    column :note, String, null: true

    index [:name], unique: false
  end
end

describe ES::ProjectionDSL do
  it "sets the table" do
    ProjectionDSLTest.table.should eq("test.postings")
  end

  describe "compiled_definition" do
    it "returns a valid JSON string" do
      defn = ProjectionDSLTest.compiled_definition
      parsed = JSON.parse(defn)
      parsed["table"].as_s.should eq("test.postings")
    end

    it "includes all columns with correct names" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      names = parsed["columns"].as_a.map { |c| c["name"].as_s }
      names.should eq(["id", "name", "amount", "comment", "score", "active", "created_at"])
    end

    it "maps Crystal types to the correct SQL types" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      cols = parsed["columns"].as_a
      col = ->(name : String) { cols.find! { |c| c["name"].as_s == name } }

      col.call("id")["sql_type"].as_s.should eq("SERIAL")
      col.call("name")["sql_type"].as_s.should eq("TEXT")
      col.call("amount")["sql_type"].as_s.should eq("BIGINT")
      col.call("score")["sql_type"].as_s.should eq("DOUBLE PRECISION")
      col.call("active")["sql_type"].as_s.should eq("BOOLEAN")
      col.call("created_at")["sql_type"].as_s.should eq("TIMESTAMPTZ")
    end

    it "records the Crystal source type for each column" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      cols = parsed["columns"].as_a
      col = ->(name : String) { cols.find! { |c| c["name"].as_s == name } }

      col.call("id")["crystal_type"].as_s.should eq("Int32")
      col.call("name")["crystal_type"].as_s.should eq("String")
      col.call("amount")["crystal_type"].as_s.should eq("Int64")
      col.call("active")["crystal_type"].as_s.should eq("Bool")
      col.call("created_at")["crystal_type"].as_s.should eq("Time")
    end

    it "records nullability" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      cols = parsed["columns"].as_a
      col = ->(name : String) { cols.find! { |c| c["name"].as_s == name } }

      col.call("name")["null"].as_bool.should be_false
      col.call("comment")["null"].as_bool.should be_true
    end

    it "records defaults" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      cols = parsed["columns"].as_a
      active = cols.find! { |c| c["name"].as_s == "active" }
      active["default"].as_bool.should be_true

      no_default = cols.find! { |c| c["name"].as_s == "name" }
      no_default["default"].raw.should be_nil
    end

    it "includes all indexes with correct names" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      idx_names = parsed["indexes"].as_a.map { |i| i["name"].as_s }
      idx_names.should contain("postings_name_idx")
      idx_names.should contain("postings_name_amount_uidx")
    end

    it "auto-generates default index name from table and column names" do
      parsed = JSON.parse(ProjectionDSLTest.compiled_definition)
      auto_idx = parsed["indexes"].as_a.find! { |i| i["name"].as_s == "postings_name_idx" }
      auto_idx["unique"].as_bool.should be_false
      auto_idx["columns"].as_a.map(&.as_s).should eq(["name"])
    end

    it "returns the same string on repeated calls (deterministic)" do
      ProjectionDSLTest.compiled_definition.should eq(ProjectionDSLTest.compiled_definition)
    end
  end

  describe "compiled_fingerprint" do
    it "returns a 64-character hex SHA-256 string" do
      fp = ProjectionDSLTest.compiled_fingerprint
      fp.size.should eq(64)
      fp.should match(/\A[0-9a-f]+\z/)
    end

    it "is deterministic across calls" do
      ProjectionDSLTest.compiled_fingerprint.should eq(ProjectionDSLTest.compiled_fingerprint)
    end

    it "differs between projections with different schemas" do
      ProjectionDSLTest.compiled_fingerprint.should_not eq(ProjectionDSLTestV2.compiled_fingerprint)
    end
  end
end

describe ES::ProjectionMeta do
  describe ".diff" do
    it "returns empty changes when definitions are identical" do
      defn = ProjectionDSLTest.compiled_definition
      changes = ES::ProjectionMeta.diff(defn, defn)
      changes.should be_empty
    end

    it "detects a removed column as breaking" do
      stored = ProjectionDSLTestV2.compiled_definition

      # Build compiled def with one fewer column
      parsed = JSON.parse(stored)
      cols = parsed["columns"].as_a[0..-2] # drop last column
      shorter = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", cols
          j.field "indexes", parsed["indexes"]
        end
      end

      changes = ES::ProjectionMeta.diff(stored, shorter)
      changes.any? { |c| c.kind == "column_removed" && c.severity == "breaking" }.should be_true
    end

    it "detects an added column as breaking" do
      stored = ProjectionDSLTestV2.compiled_definition
      compiled = ProjectionDSLTest.compiled_definition # has more columns

      # stored has 4 columns, ProjectionDSLTest has 7 — so positions differ
      # Use a simpler pair: same base + one extra
      base = ProjectionDSLTestV2.compiled_definition
      parsed = JSON.parse(base)
      extra_col = JSON.parse(%({"name":"extra","sql_type":"TEXT","primary_key":false,"null":true,"default":null,"position":4}))
      cols = parsed["columns"].as_a + [extra_col]
      longer = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", cols
          j.field "indexes", parsed["indexes"]
        end
      end

      changes = ES::ProjectionMeta.diff(base, longer)
      changes.any? { |c| c.kind == "column_added" && c.severity == "breaking" }.should be_true
    end

    it "detects a column type change as breaking" do
      base = ProjectionDSLTestV2.compiled_definition
      parsed = JSON.parse(base)
      cols = parsed["columns"].as_a.map do |c|
        if c["name"].as_s == "amount"
          JSON.parse(%({"name":"amount","sql_type":"TEXT","primary_key":false,"null":false,"default":null,"position":2}))
        else
          c
        end
      end
      modified = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", cols
          j.field "indexes", parsed["indexes"]
        end
      end

      changes = ES::ProjectionMeta.diff(base, modified)
      changes.any? { |c| c.kind == "column_type_changed" && c.severity == "breaking" }.should be_true
    end

    it "detects a Crystal type change as breaking even when sql_type is identical" do
      # Reproduces the serial: true bug: Int32 vs Int64 both produce sql_type SERIAL
      # but they differ in crystal_type and must be caught.
      base = ProjectionDSLTestV2.compiled_definition
      parsed = JSON.parse(base)
      cols = parsed["columns"].as_a.map do |c|
        if c["name"].as_s == "id"
          JSON.parse(%({"name":"id","sql_type":"SERIAL","crystal_type":"Int64","primary_key":true,"null":false,"default":null,"position":0}))
        else
          c
        end
      end
      modified = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", cols
          j.field "indexes", parsed["indexes"]
        end
      end

      changes = ES::ProjectionMeta.diff(base, modified)
      changes.any? { |c| c.kind == "column_crystal_type_changed" && c.severity == "breaking" }.should be_true
    end

    it "detects a primary_key change as breaking" do
      base = ProjectionDSLTestV2.compiled_definition
      parsed = JSON.parse(base)
      cols = parsed["columns"].as_a.map do |c|
        if c["name"].as_s == "id"
          JSON.parse(%({"name":"id","sql_type":"SERIAL","crystal_type":"Int32","primary_key":false,"null":false,"default":null,"position":0}))
        else
          c
        end
      end
      modified = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", cols
          j.field "indexes", parsed["indexes"]
        end
      end

      changes = ES::ProjectionMeta.diff(base, modified)
      changes.any? { |c| c.kind == "column_primary_key_changed" && c.severity == "breaking" }.should be_true
    end

    it "detects a removed index as non_breaking" do
      stored = ProjectionDSLTestV2.compiled_definition
      parsed = JSON.parse(stored)
      no_indexes = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", parsed["columns"]
          j.field "indexes", [] of JSON::Any
        end
      end

      changes = ES::ProjectionMeta.diff(stored, no_indexes)
      changes.any? { |c| c.kind == "index_removed" && c.severity == "non_breaking" }.should be_true
      changes.none? { |c| c.severity == "breaking" }.should be_true
    end

    it "detects an added index as non_breaking" do
      base = ProjectionDSLTestV2.compiled_definition
      parsed = JSON.parse(base)
      extra_idx = JSON.parse(%({"columns":["amount"],"unique":false,"name":"postings_v2_amount_idx"}))
      with_extra = JSON.build do |j|
        j.object do
          j.field "table", parsed["table"].as_s
          j.field "columns", parsed["columns"]
          j.field "indexes", parsed["indexes"].as_a + [extra_idx]
        end
      end

      changes = ES::ProjectionMeta.diff(base, with_extra)
      changes.any? { |c| c.kind == "index_added" && c.severity == "non_breaking" }.should be_true
      changes.none? { |c| c.severity == "breaking" }.should be_true
    end
  end
end

# `column`/`index` declarations carrying no options at all: the AST node exposes
# `named_args` as Nop rather than an empty list, which used to abort compilation.
class ProjectionDSLNoOptions < ES::Projection
  include ES::ProjectionDSL

  define_projection "projections.no_options" do
    column :id, UUID, primary_key: true
    column :account_id, UUID
    column :amount, Int64

    index [:account_id]
  end
end

describe "ES::ProjectionDSL with option-less declarations" do
  it "compiles a column declared without any options" do
    parsed = JSON.parse(ProjectionDSLNoOptions.compiled_definition)
    cols = parsed["columns"].as_a

    cols.map(&.["name"].as_s).should eq(["id", "account_id", "amount"])
    cols[1]["sql_type"].as_s.should eq("UUID")
    cols[1]["primary_key"].as_bool.should be_false
    cols[1]["null"].as_bool.should be_false
  end

  it "compiles an index declared without any options" do
    parsed = JSON.parse(ProjectionDSLNoOptions.compiled_definition)
    idxs = parsed["indexes"].as_a

    idxs.size.should eq(1)
    idxs[0]["unique"].as_bool.should be_false
    idxs[0]["name"].as_s.should eq("no_options_account_id_idx")
  end
end
