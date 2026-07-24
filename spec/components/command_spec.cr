require "../spec_helper"

describe ES::Command do
  it "carries the target aggregate id" do
    id = UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e")
    command = DummyCommand.new(aggregate_id: id)

    command.aggregate_id.should eq(id)
  end

  it "has value semantics" do
    id = UUID.new("7efe288b-8d33-4359-b799-fd71b32a648e")

    DummyCommand.new(aggregate_id: id).should eq(DummyCommand.new(aggregate_id: id))
  end
end
