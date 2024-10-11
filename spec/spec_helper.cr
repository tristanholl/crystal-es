require "db"
require "spec"
require "../src/crystal-es"

# Mocking the database for faster testing
module DBMock
  class Database < DB::Database
    def initialize
      @connection_options = DB::Connection::Options.new
      @setup_connection = ->(conn : DB::Connection) {}
      @pool = uninitialized DB::Pool(DB::Connection)
    end
  end

  def self.open
    Database.new
  end
end

# Default Event
class DummyEvent < ES::Event
  @@aggregate = "Test"
  @@handle = "dummy"

  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize(@comment)
    end
  end

  def initialize(
    @header : ES::Event::Header,
    body : JSON::Any
  )
    @body = Body.from_json(body.to_json)
  end

  def initialize
    @header = Header.new(
      aggregate_id: UUID.v7,
      aggregate_type: "Test",
      aggregate_version: 1,
      command_handler: "test",
      event_handle: @@handle
    )
    @body = Body.new("comment")
  end
end

# Default Command
class DummyCommand < ES::Command
  getter test_attribute : Bool = false

  def call
    @test_attribute = true
  end
end
