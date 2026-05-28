require "../spec_helper"

class ProjectionDSLTest < ES::Projection
  include ES::ProjectionDSL

  define_projection "dsl_test", "test.postings" do
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

class ProjectionDSLNoBlock < ES::Projection
  include ES::ProjectionDSL

  define_projection "dsl_no_block", "public.no_block_table"
end

describe ES::ProjectionDSL do
  it "sets the handle" do
    ProjectionDSLTest.handle.should eq("dsl_test")
  end

  it "sets the table" do
    ProjectionDSLTest.table.should eq("test.postings")
  end

  it "works without a column block" do
    ProjectionDSLNoBlock.handle.should eq("dsl_no_block")
    ProjectionDSLNoBlock.table.should eq("public.no_block_table")
  end
end
