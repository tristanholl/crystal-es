require "../spec_helper"

describe ES::Exception::InvalidEventStream do
  it "defaults to 'Invalid event stream' at 500" do
    exception = ES::Exception::InvalidEventStream.new

    exception.message.should eq("Invalid event stream")
    exception.status_code.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
  end
end
