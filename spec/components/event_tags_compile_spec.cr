require "../spec_helper"
require "file_utils"

# `tag` declarations are checked when the event compiles, and a key declared
# hashed in one event but not in another raises a compile-time warning. Each case
# compiles a small program in a subprocess (semantic pass only, no codegen). It
# runs from the repository root so the compiler finds the shards in lib/.
private ROOT = File.expand_path("../..", __DIR__)

private def compile_events(source_body : String) : {Bool, String}
  # Crystal only resolves relative requires, hence the path relative to `dir`.
  dir = File.realpath(Dir.tempdir) + "/" + File.basename(File.tempname("crystal_es_tag_checks"))
  Dir.mkdir_p(dir)
  source = File.join(dir, "main.cr")
  File.write(source, <<-CRYSTAL)
    require "db"
    require "#{Path[ROOT, "src", "crystal-es"].relative_to(dir)}"

    #{source_body}
    CRYSTAL

  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", source], output: output, error: output, chdir: ROOT)
  {status.success?, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir
end

private def event_with(declarations : String, name = "TagCheckEvent", handle = "tag_check") : String
  <<-CRYSTAL
    class #{name} < ES::Event
      include ES::EventDSL

      define_event "test", "#{handle}" do
        attribute :course_id, UUID
        attribute :email, String
        #{declarations}
      end
    end
    CRYSTAL
end

describe "ES::EventDSL tag compile-time checks" do
  it "accepts valid declarations without a warning (control)" do
    ok, output = compile_events(
      event_with("tag :course_id, UUID\ntag :email, String, hashed: true\ntag :other_id, UUID?") +
      %(\nTagCheckEvent.new(actor_id: nil, command_handler: "x", course_id: UUID.v7, email: "e", tags: {course_id: UUID.v7, email: "e", other_id: nil}))
    )
    fail output unless ok
    output.should_not contain("Warning")
  end

  {
    %(tag :email)                                  => "takes a name and a type",
    %(tag :email, String\ntag :email, String)      => "is declared twice",
    %(tag :email, String, hashed: "yes")           => "expects `hashed:` to be true or false",
    %(tag :email, String, hashd: true)             => "unknown option 'hashd'",
    %(tag "email", String)                         => "expects a symbol as its name",
    %(tag :email, String, UUID)                    => "takes a name and a type",
    %(attribute :tags, String\ntag :email, String) => "attribute :tags clashes",
    %(something_else :email)                       => "only accepts `attribute` and `tag` declarations",
  }.each do |declaration, message|
    it "rejects `#{declaration.gsub('\n', "; ")}`" do
      ok, output = compile_events(event_with(declaration))
      ok.should be_false
      output.should contain(message)
    end
  end

  it "refuses a tags argument that does not match the declarations" do
    ok, output = compile_events(event_with("tag :course_id, UUID") + %(\nTagCheckEvent.new(actor_id: nil, command_handler: "x", course_id: UUID.v7, email: "e", tags: {course_id: "not a uuid"})))

    ok.should be_false
    output.should contain("tags")
  end

  it "refuses a tags argument on an event without tags" do
    ok, output = compile_events(event_with("") + %(\nTagCheckEvent.new(actor_id: nil, command_handler: "x", course_id: UUID.v7, email: "e", tags: {course_id: UUID.v7})))

    ok.should be_false
    output.should contain("tags")
  end

  it "refuses to append an array of something other than events" do
    ok, output = compile_events(%(ES::EventStoreAdapters::InMemory.new.append(["not an event"])))

    ok.should be_false
    output.should contain("append expects an array of events, got Array(String)")
  end

  it "warns when a key is hashed in one event but not in another" do
    ok, output = compile_events(
      event_with("tag :email, String, hashed: true", "HashedEmailEvent", "hashed_email") + "\n" +
      event_with("tag :email, String", "PlainEmailEvent", "plain_email")
    )

    fail output unless ok
    output.should contain("Warning: Tag 'email' is declared hashed: true in HashedEmailEvent but hashed: false in PlainEmailEvent")
  end

  it "does not warn when every event declares a key the same way" do
    ok, output = compile_events(
      event_with("tag :email, String, hashed: true\ntag :course_id, UUID", "FirstEvent", "first") + "\n" +
      event_with("tag :email, String, hashed: true", "SecondEvent", "second") + "\n" +
      event_with("tag :course_id, UUID, hashed: false", "ThirdEvent", "third")
    )

    fail output unless ok
    output.should_not contain("Warning")
  end
end
