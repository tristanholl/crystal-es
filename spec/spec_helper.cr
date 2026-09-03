require "db"
require "spec"
require "../src/crystal-es"

# Mocking the database for faster testing
module DBMock
  class Database < DB::Database
    def initialize
      @connection_options = DB::Connection::Options.new
      @setup_connection = ->(_conn : DB::Connection) { }
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
    body : JSON::Any,
  )
    @body = Body.from_json(body.to_json)
  end

  def initialize
    @header = Header.new(
      actor_id: UUID.v7,
      aggregate_id: UUID.v7,
      aggregate_type: "Test",
      aggregate_version: 1,
      command_handler: "test",
      event_handle: @@handle
    )
    @body = Body.new("comment")
  end
end

# An event whose body must be encrypted. `encrypted: true` makes
# `encryption_key_id` a required argument of the generated constructor.
class EncryptedEvent < ES::Event
  include ::ES::EventDSL

  define_event "Test", "encrypted_dummy", encrypted: true do
    attribute :secret, String
  end
end

# The same shape without the declaration, for comparing the two paths
class PlainEvent < ES::Event
  include ::ES::EventDSL

  define_event "Test", "plain_dummy" do
    attribute :secret, String
  end
end

# An application key manager backed by a freshly generated key
def test_application_key : ES::ApplicationEncryptionKeyManager
  ES::ApplicationEncryptionKeyManager.new(ES::PayloadCipher.random_key)
end

# An encryption key manager wired to an in-memory keystore
def test_encryption(application_key : ES::ApplicationEncryptionKeyManager = test_application_key) : ES::EncryptionKeyManager
  ES::EncryptionKeyManager.new(ES::KeyStoreAdapters::InMemory.new, application_key)
end

# A registry knowing the encrypted and plain test events
def test_event_handlers : ES::EventHandlers
  handlers = ES::EventHandlers.new
  handlers.register(EncryptedEvent)
  handlers.register(PlainEvent)
  handlers
end

# Default Command — a pure data record
struct DummyCommand < ES::Command
  def initialize(@aggregate_id : UUID = UUID.v7)
  end
end

# Default Command Handler — generic over its command type
class DummyCommandHandler < ES::CommandHandler(DummyCommand)
  getter handled : Bool = false

  def handle(command : DummyCommand)
    @handled = true
  end
end

# Default Reactor — reacts to an event by recording the invocation
class DummyReactor < ES::Reactor
  class_property invocations : Int32 = 0

  def call(event : DummyEvent)
    DummyReactor.invocations += 1
  end
end

# A second event, used to exercise multi-event reactors and subscription checks
class OtherDummyEvent < ES::Event
  @@aggregate = "Test"
  @@handle = "other_dummy"

  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize(@comment)
    end
  end

  def initialize(
    @header : ES::Event::Header,
    body : JSON::Any,
  )
    @body = Body.from_json(body.to_json)
  end

  def initialize
    @header = Header.new(
      actor_id: UUID.v7,
      aggregate_id: UUID.v7,
      aggregate_type: "Test",
      aggregate_version: 1,
      command_handler: "test",
      event_handle: @@handle
    )
    @body = Body.new("comment")
  end
end

# A reactor handling two events — impossible with the previous `reacts_to` macro,
# which redefined the erased entry point on each call
class MultiEventReactor < ES::Reactor
  class_property seen : Array(String) = [] of String

  def call(event : DummyEvent)
    MultiEventReactor.seen << "DummyEvent"
  end

  def call(event : OtherDummyEvent)
    MultiEventReactor.seen << "OtherDummyEvent"
  end
end
