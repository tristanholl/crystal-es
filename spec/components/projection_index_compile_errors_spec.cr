require "../spec_helper"
require "file_utils"

# Invalid `index` declarations must fail at compile time. Each case compiles a
# small program in a subprocess (semantic pass only, no codegen). It runs from
# the repository root so the compiler finds the shards in lib/.
private ROOT = File.expand_path("../..", __DIR__)

private def compile_index(declaration : String) : {Bool, String}
  # Crystal only resolves relative requires, hence the path relative to `dir`.
  dir = File.realpath(Dir.tempdir) + "/" + File.basename(File.tempname("crystal_es_index_errors"))
  Dir.mkdir_p(dir)
  source = File.join(dir, "main.cr")
  File.write(source, <<-CRYSTAL)
    require "db"
    require "#{Path[ROOT, "src", "crystal-es"].relative_to(dir)}"

    class InvalidIndexProjection < ES::Projection
      include ES::ProjectionDSL

      define_projection "test.invalid_index" do
        column :id, UUID, primary_key: true
        column :name, String
        column :status, String

        #{declaration}
      end
    end

    InvalidIndexProjection.compiled_definition
    CRYSTAL

  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", source], output: output, error: output, chdir: ROOT)
  {status.success?, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "ES::ProjectionDSL index compile-time checks" do
  it "accepts a valid declaration (control)" do
    ok, output = compile_index(%(index [:name], using: :gin, opclass: :gin_trgm_ops, name: "n_trgm_idx"))
    fail output unless ok
  end

  {
    %(index ["lower(name)"])                                   => "needs an explicit name:",
    %(index [:id], where: "status = 'open'")                   => "needs an explicit name:",
    %(index [:name], using: :gin, opclass: :gin_trgm_ops)      => "needs an explicit name:",
    %(index [:name], using: :brin, name: "n_idx")              => "index using: must be one of",
    %(index [:name, :id], opclass: [:text_pattern_ops])        => "opclass: array has 1 entries",
    %(index [:name], opclass: "gin_trgm_ops; DROP TABLE x")    => "is not a valid operator class name",
    %(index [:name], wher: "status = 'open'", name: "n_idx")   => "unknown index option",
    %(index [:name], using: :gin, include: [:id], name: "n_i") => "include: is only supported",
    %(index [1])                                               => "index entries must be column symbols",
  }.each do |declaration, message|
    it "rejects `#{declaration}`" do
      ok, output = compile_index(declaration)
      ok.should be_false
      output.should contain(message)
    end
  end
end
