require "../../spec_helper"

describe ES::QueueAdapters::InMemory do
  it "Appends and returns item" do
    q = ES::QueueAdapters::InMemory.new("test_queue")
    e = DummyEvent.new

    event_id = e.header.event_id

    c : Channel(ES::Queue::Entry) = q.listen
    q.append(e)

    qe = c.receive
    queue_entry_event_id = qe.header.event_id
    queue_entry_event_id.should eq(event_id)
  end

  it "Appends and deletes item" do
    q = ES::QueueAdapters::InMemory.new("test_queue")
    e = DummyEvent.new  # msg_id=0
    e2 = DummyEvent.new # msg_id=1

    event2_id = e2.header.event_id
    q.append(e)
    q.delete(0)
    q.append(e2)

    c : Channel(ES::Queue::Entry) = q.listen(visibility_timeout: 1.seconds)
    qe2 = c.receive
    queue_entry_event_id = qe2.header.event_id
    queue_entry_event_id.should eq(event2_id)
  end
end
