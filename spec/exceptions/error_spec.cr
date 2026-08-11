require "../spec_helper"

class TestDummyError < ES::Exception::Error; end

# The mechanism every ES::Exception subclass relies on: passing message/status_code
# through to the base class, and building the Information record from them. Each
# subclass spec only needs to assert its own hardcoded defaults after this.
describe ES::Exception::Error do
  it "defaults to a generic message, no backtrace, and a 500 status" do
    exception = TestDummyError.new

    exception.message.should eq("Generic Error")
    exception.print_backtrace?.should be_false
    exception.status_code.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
  end

  it "stores the message and status_code it was given instead of the defaults" do
    exception = TestDummyError.new("Test message", print_backtrace: true, status_code: HTTP::Status::SERVICE_UNAVAILABLE)

    exception.message.should eq("Test message")
    exception.print_backtrace?.should be_true
    exception.status_code.should eq(HTTP::Status::SERVICE_UNAVAILABLE)
  end

  it "builds an info record carrying the message and the concrete subclass name" do
    exception = TestDummyError.new("Test message")

    exception.info.message.should eq("Test message")
    exception.info.type.should eq("TestDummyError")
  end
end
