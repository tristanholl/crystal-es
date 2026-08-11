require "../spec_helper"

describe ES::Exception::InvalidState do
  it "defaults to 'Invalid state' at 500" do
    exception = ES::Exception::InvalidState.new

    exception.message.should eq("Invalid state")
    exception.status_code.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
  end
end
