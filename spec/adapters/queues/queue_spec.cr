require "../../spec_helper"

class MyQueue < ES::Queue
  def setup
    # Noop
  end

  def read(name : String) : Array(ES::Queue::Entry)
  end

  def archive(name : String, msg_id : Int64)
  end

  def delete(name : String, msg_id : Int64)
  end
end

describe ES::Queue do
  it "allows to instantiate a child class" do
    store = MyQueue.new
    store.class.should eq(MyQueue)
  end
end
