require "../spec_helper"

describe ES::Exception::NotImplemented do
  it "defaults to 'Not implemented' at 500" do
    exception = ES::Exception::NotImplemented.new

    exception.message.should eq("Not implemented")
    exception.status_code.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
  end
end
