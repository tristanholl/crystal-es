require "../spec_helper"

class TestDummyEvent < ES::Event
  @@aggregate = "TestDummyAggregate"
  @@handle = "test.dummy.event"

  struct Body < ES::Event::Body
    include JSON::Serializable

    getter test : String

    def initialize(
      @test : String,
      @comment : String
    )
    end
  end

  def initialize(
    aggregate_id : UUID,
    test : String,
    command_handler = "undefined",
    comment = ""
  )
    @header = Header.new(
      aggregate_id: aggregate_id,
      aggregate_type: @@aggregate,
      aggregate_version: 1,
      event_handle: @@handle
    )
    @body = Body.new(
      test: test,
      comment: comment
    )
  end
end

describe ES::Event do
  it "returns the correct class aggregate" do 
    TestDummyEvent.aggregate.should eq("TestDummyAggregate")
  end

  it "returns the correct class handle" do 
    TestDummyEvent.handle.should eq("test.dummy.event")
  end

  it "creates the event" do
    e = TestDummyEvent.new(
      aggregate_id: UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"),
      test: "test",
      comment: "test comment"
    )

    h = e.header
    h.aggregate_id.should eq(UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"))
    h.aggregate_type.should eq("TestDummyAggregate")
    h.aggregate_version.should eq(1)
    h.command_handler.should eq("undefined")
    h.command_handler_version.should eq(ES::Config.version)
    h.event_handle.should eq("test.dummy.event")
    h.event_id.class.should eq(UUID)
    h.event_version.should eq("1.0.0")

    b = e.body.as(TestDummyEvent::Body)
    b.test.should eq("test")
  end

  it "body can be serialized to json" do
    e = TestDummyEvent.new(
      aggregate_id: UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"),
      test: "test",
      comment: "test comment"
    )

    e.body.to_json.should eq(%({"comment":"test comment","test":"test"}))
  end
end
