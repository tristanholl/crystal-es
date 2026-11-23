require "../spec_helper"
require "file_utils"

# Decision projections are checked when they compile. Each case compiles a small
# program in a subprocess (semantic pass only, no codegen). It runs from the
# repository root so the compiler finds the shards in lib/.
private ROOT = File.expand_path("../..", __DIR__)

private EVENTS = <<-CRYSTAL
  class CheckCourseDefined < ES::Event
    include ES::EventDSL

    define_event "course", "decision_check.course_defined" do
      attribute :capacity, Int32
      tag :course_id, UUID
    end
  end

  class CheckUntagged < ES::Event
    include ES::EventDSL

    define_event "course", "decision_check.untagged" do
      attribute :note, String
    end
  end
  CRYSTAL

private def compile_projection(source_body : String) : {Bool, String}
  # Crystal only resolves relative requires, hence the path relative to `dir`.
  dir = File.realpath(Dir.tempdir) + "/" + File.basename(File.tempname("crystal_es_decision_checks"))
  Dir.mkdir_p(dir)
  source = File.join(dir, "main.cr")
  File.write(source, <<-CRYSTAL)
    require "db"
    require "#{Path[ROOT, "src", "crystal-es"].relative_to(dir)}"

    #{EVENTS}
    #{source_body}
    CRYSTAL

  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", source], output: output, error: output, chdir: ROOT)
  {status.success?, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir
end

private def projection_with(declarations : String) : String
  <<-CRYSTAL
    class CheckProjection < ES::DecisionProjection(Int32)
      def initialize(@course_id : UUID); end

      def initial_state : State
        0
      end

      #{declarations}
    end

    ES::EventStoreAdapters::InMemory.new.build_decision_model(check: CheckProjection.new(UUID.v7))
    CRYSTAL
end

private VALID_HANDLER = "on CheckCourseDefined do |_state, _event|\n  body.capacity\nend"

describe "ES::DecisionProjection compile-time checks" do
  it "accepts a valid projection (control)" do
    ok, output = compile_projection(projection_with("tags course_id: @course_id\n#{VALID_HANDLER}\non_erased CheckCourseDefined do |state, _header|\n  state\nend"))
    fail output unless ok
  end

  {
    "tags course_id: @course_id"                                                                              => "handles no events",
    VALID_HANDLER                                                                                             => "names no tags",
    "tags course_id: @course_id\ntags course_id: @course_id\n#{VALID_HANDLER}"                                => "declares `tags` twice",
    "tags @course_id\n#{VALID_HANDLER}"                                                                       => "tags takes named tags only",
    "tags course_id: @course_id\n#{VALID_HANDLER}\n#{VALID_HANDLER}"                                          => "handles CheckCourseDefined twice",
    "tags student_id: @course_id\n#{VALID_HANDLER}"                                                           => "tag :student_id, which CheckCourseDefined does not declare",
    "tags course_id: @course_id\non CheckUntagged do |state, _event|\n  state\nend"                           => "tag :course_id, which CheckUntagged does not declare",
    "tags course_id: @course_id\non String do |state, _event|\n  state\nend"                                  => "handles String, which is not an ES::Event",
    "tags course_id: @course_id\non CheckCourseDefined do |state|\n  state\nend"                              => "expects a block taking |state, event|",
    "tags course_id: @course_id\non CheckCourseDefined"                                                       => "expects a block taking |state, event|",
    "tags course_id: @course_id\n#{VALID_HANDLER}\non_erased CheckUntagged do |state, _header|\n  state\nend" => "on_erased CheckUntagged without `on CheckUntagged`",
    "tags course_id: @course_id\n#{VALID_HANDLER}\non_erased CheckCourseDefined do |state|\n  state\nend"     => "on_erased CheckCourseDefined expects a block taking |state, header|",
  }.each do |declarations, message|
    it "refuses: #{message}" do
      ok, output = compile_projection(projection_with(declarations))
      ok.should be_false
      output.should contain(message)
    end
  end

  it "refuses build_decision_model without projections" do
    ok, output = compile_projection("ES::EventStoreAdapters::InMemory.new.build_decision_model")
    ok.should be_false
    output.should contain("needs at least one projection")
  end

  it "refuses build_decision_model with something other than a projection" do
    ok, output = compile_projection(%(ES::EventStoreAdapters::InMemory.new.build_decision_model(check: "nope")))
    ok.should be_false
    output.should contain("'check' is a String, not an ES::DecisionProjection")
  end
end
