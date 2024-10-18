require "../../spec_helper"

class MyQueue < ES::Queue
  def setup
    # Noop
  end

  def read(timeout : Time::Span, count : Int32) : Array(ES::Queue::Entry)
  end

  def archive(msg_id : Int64)
  end

  def delete(msg_id : Int64)
  end
end

describe ES::Queue do
  it "allows to instantiate a child class" do
    store = MyQueue.new("test")
    store.class.should eq(MyQueue)
  end
end
