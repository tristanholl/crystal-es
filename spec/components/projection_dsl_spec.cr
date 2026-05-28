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

describe ES::ProjectionDSL do
  it "sets the handle" do
    ProjectionDSLTest.handle.should eq("dsl_test")
  end

  it "sets the table" do
    ProjectionDSLTest.table.should eq("test.postings")
  end

  it "raises a compile error when defined without a column block" do
    source = <<-CRYSTAL
      require "./src/crystal-es"
      class BadProjection < ES::Projection
        include ES::ProjectionDSL
        define_projection "bad", "schema.table"
      end
    CRYSTAL

    stderr = IO::Memory.new
    status = Process.run("crystal", ["eval", source], error: stderr, chdir: "#{__DIR__}/../..")
    status.success?.should be_false
    stderr.to_s.should contain("define_projection requires at least one column declaration")
  end
end
