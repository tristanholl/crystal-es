require "../spec_helper"

# Every `index` option introduced alongside expression, GIN/trigram, partial
# and covering indexes.
class ProjectionIndexOptionsTest < ES::Projection
  include ES::ProjectionDSL

  define_projection "test.index_options" do
    column :id, UUID, primary_key: true
    column :name, String
    column :email, String
    column :status, String
    column :amount, Int64

    index [:email]
    index ["lower(email)"], name: "index_options_email_lower_idx"
    index [:name], using: :gin, opclass: :gin_trgm_ops, name: "index_options_name_trgm_idx"
    index [:id], where: "status = 'open'", name: "index_options_open_id_idx"
    index [:status, :amount], include: [:name], name: "index_options_status_cover_idx"
    index [:name, "lower(email)"], opclass: [:text_pattern_ops, nil], unique: true, name: "index_options_mixed_uidx"
    index [:name], opclass: :text_pattern_ops
  end
end

private def index_entry(name : String) : JSON::Any
  JSON.parse(ProjectionIndexOptionsTest.compiled_definition)["indexes"].as_a.find! { |idx| idx["name"].as_s == name }
end

private def index_sql(name : String) : String
  ProjectionIndexOptionsTest.index_ddl.find! { |(idx_name, _)| idx_name == name }[1]
end

# A definition holding just the given index entries, for `ProjectionMeta.diff`
private def definition_with(*indexes : String) : String
  %({"table":"test.t","columns":[],"indexes":[#{indexes.join(",")}]})
end

describe "ES::ProjectionDSL index options" do
  describe "index_ddl" do
    it "keeps plain column indexes unchanged" do
      index_sql("index_options_email_idx").should eq(
        %(CREATE INDEX IF NOT EXISTS index_options_email_idx ON "test"."index_options" ("email")))
    end

    it "wraps a string entry in parentheses as an expression" do
      index_sql("index_options_email_lower_idx").should eq(
        %(CREATE INDEX IF NOT EXISTS index_options_email_lower_idx ON "test"."index_options" ((lower(email)))))
    end

    it "emits USING and the operator class" do
      index_sql("index_options_name_trgm_idx").should eq(
        %(CREATE INDEX IF NOT EXISTS index_options_name_trgm_idx ON "test"."index_options" USING gin ("name" gin_trgm_ops)))
    end

    it "emits a WHERE predicate" do
      index_sql("index_options_open_id_idx").should eq(
        %(CREATE INDEX IF NOT EXISTS index_options_open_id_idx ON "test"."index_options" ("id") WHERE status = 'open'))
    end

    it "emits INCLUDE columns" do
      index_sql("index_options_status_cover_idx").should eq(
        %(CREATE INDEX IF NOT EXISTS index_options_status_cover_idx ON "test"."index_options" ("status", "amount") INCLUDE ("name")))
    end

    it "applies a per-entry opclass array" do
      index_sql("index_options_mixed_uidx").should eq(
        %(CREATE UNIQUE INDEX IF NOT EXISTS index_options_mixed_uidx ON "test"."index_options" ("name" text_pattern_ops, (lower(email)))))
    end

    it "auto-names a plain column index that only sets an opclass" do
      index_sql("index_options_name_idx").should eq(
        %(CREATE INDEX IF NOT EXISTS index_options_name_idx ON "test"."index_options" ("name" text_pattern_ops)))
    end
  end

  describe "compiled_definition" do
    it "omits the new fields for a plain column index" do
      index_entry("index_options_email_idx").as_h.keys.should eq(["columns", "unique", "name"])
    end

    it "records expressions per entry" do
      entry = index_entry("index_options_mixed_uidx")
      entry["columns"].as_a.map(&.as_s).should eq(["name", "lower(email)"])
      entry["expressions"].as_a.map(&.as_bool).should eq([false, true])
      entry["opclass"].as_a.map(&.raw).should eq(["text_pattern_ops", nil])
    end

    it "records using and a single opclass expanded per entry" do
      entry = index_entry("index_options_name_trgm_idx")
      entry["using"].as_s.should eq("gin")
      entry["opclass"].as_a.map(&.as_s).should eq(["gin_trgm_ops"])
    end

    it "records where and include" do
      index_entry("index_options_open_id_idx")["where"].as_s.should eq("status = 'open'")
      index_entry("index_options_status_cover_idx")["include"].as_a.map(&.as_s).should eq(["name"])
    end
  end

  describe "ES::ProjectionMeta.diff" do
    plain = %({"columns":["name"],"unique":false,"name":"t_idx"})

    {
      "expressions" => %({"columns":["name"],"unique":false,"name":"t_idx","expressions":[true]}),
      "using"       => %({"columns":["name"],"unique":false,"name":"t_idx","using":"gin"}),
      "opclass"     => %({"columns":["name"],"unique":false,"name":"t_idx","opclass":["gin_trgm_ops"]}),
      "where"       => %({"columns":["name"],"unique":false,"name":"t_idx","where":"status = 'open'"}),
      "include"     => %({"columns":["name"],"unique":false,"name":"t_idx","include":["id"]}),
    }.each do |field, changed|
      it "reports an index_changed when #{field} changes" do
        changes = ES::ProjectionMeta.diff(definition_with(plain), definition_with(changed))
        changes.map(&.kind).should eq(["index_changed"])
        changes[0].index_name.should eq("t_idx")
        changes[0].description.should contain(field)
        changes[0].severity.should eq("non_breaking")
      end
    end

    it "reports a change of a where predicate" do
      before = %({"columns":["id"],"unique":false,"name":"t_idx","where":"status = 'open'"})
      after = %({"columns":["id"],"unique":false,"name":"t_idx","where":"status = 'closed'"})
      ES::ProjectionMeta.diff(definition_with(before), definition_with(after)).map(&.kind).should eq(["index_changed"])
    end

    it "treats fields missing from an old stored definition as their defaults" do
      explicit_defaults = %({"columns":["name"],"unique":false,"name":"t_idx","expressions":[false],"using":"btree","opclass":[null],"where":null,"include":[]})
      ES::ProjectionMeta.diff(definition_with(plain), definition_with(explicit_defaults)).should be_empty
    end

    it "serialises a plain index exactly as before, so its fingerprint survives the upgrade" do
      # The stored JSON of a pre-0.10.2 deploy carries only columns/unique/name.
      index_entry("index_options_email_idx").to_json.should eq(%({"columns":["email"],"unique":false,"name":"index_options_email_idx"}))
    end
  end
end
