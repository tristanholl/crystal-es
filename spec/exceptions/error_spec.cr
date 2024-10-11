require "../spec_helper"

class TestDummyError < ES::Exception::Error; end

describe ES::Exception::Error do
  it "should initialize with a message" do
    exception = TestDummyError.new("Test message")
    exception.message.should eq "Test message"
  end
end
