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

  it "creates the event with tags" do
    e = TestDummyEvent.new(
      actor_id: nil,
      aggregate_id: UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"),
      command_handler: "Test",
      test: "test",
      tags: {"course:1" => 3}
    )

    e.header.tags.should eq({"course:1" => 3})
  end

  it "defaults tags to an empty hash" do
    e = TestDummyEvent.new(
      actor_id: nil,
      command_handler: "Test",
      test: "test"
    )

    e.header.tags.should eq({} of String => Int32)
  end

  it "returns all sequence memberships including the primary aggregate" do
    e = TestDummyEvent.new(
      actor_id: nil,
      aggregate_id: UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e"),
      aggregate_version: 2,
      command_handler: "Test",
      test: "test",
      tags: {"course:1" => 3}
    )

    e.memberships.should eq({
      "7efe288b-8d33-4359-b799-fd71b32a648e" => 2,
      "course:1"                             => 3,
    })
  end

  it "header round-trips tags through json" do
    e = TestDummyEvent.new(
      actor_id: nil,
      command_handler: "Test",
      test: "test",
      tags: {"course:1" => 3}
    )

    h = ES::Event::Header.from_json(e.header.to_json)
    h.tags.should eq({"course:1" => 3})
  end

  it "header without tags parses to an empty hash" do
    json = %({"aggregate_id":"7efe288b-8d33-4359-b799-fd71b32a648e","aggregate_type":"Test","aggregate_version":1,"command_handler":"Test","command_handler_version":"unknown","created_at":"2026-01-01T00:00:00Z","event_handle":"test.dummy.event","event_id":"0197b7a2-91cd-7b21-b7be-cfdaf40ae199","event_version":"1.0.0"})

    h = ES::Event::Header.from_json(json)
    h.tags.should eq({} of String => Int32)
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
