require "../spec_helper"

class TestDummyEvent < ES::Event
  include ::ES::EventDSL

  define_event "TestDummyAggregate", "test.dummy.event" do
    attribute :test, String
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
      actor_id: UUID.new("43ab4533-d06c-4086-bce9-83a7642fb666"),
      aggregate_id: UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"),
      command_handler: "Test",
      test: "test",
      comment: "test comment"
    )

    h = e.header
    h.actor_id.should eq(UUID.new("43ab4533-d06c-4086-bce9-83a7642fb666"))
    h.aggregate_id.should eq(UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"))
    h.aggregate_type.should eq("TestDummyAggregate")
    h.aggregate_version.should eq(1)
    h.command_handler.should eq("Test")
    h.command_handler_version.should eq(ES::Config.version)
    h.event_handle.should eq("test.dummy.event")
    h.event_id.class.should eq(UUID)
    h.event_version.should eq("1.0.0")

    b = e.body.as(TestDummyEvent::Body)
    b.test.should eq("test")
  end

  it "body can be serialized to json" do
    e = TestDummyEvent.new(
      actor_id: UUID.new("43ab4533-d06c-4086-bce9-83a7642fb666"),
      aggregate_id: UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"),
      command_handler: "Test",
      test: "test",
      comment: "test comment"
    )

    e.body.to_json.should eq(%({"comment":"test comment","test":"test"}))
  end
end
