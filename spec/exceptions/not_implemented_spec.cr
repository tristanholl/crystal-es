require "../spec_helper"

describe ES::Exception::NotImplemented do
  it "should initialize with a message" do
    exception = ES::Exception::NotImplemented.new("Test message")
    exception.message.should eq "Test message"
  end

  it "should initialize with a default message" do
    exception = ES::Exception::NotImplemented.new
    exception.message.should eq "Not implemented"
  end

  it "should initialize with a status code" do
    exception = ES::Exception::NotImplemented.new(status_code: HTTP::Status::SERVICE_UNAVAILABLE)
    exception.status_code.should eq HTTP::Status::SERVICE_UNAVAILABLE
  end

  it "should initialize with a default status code" do
    exception = ES::Exception::NotImplemented.new
    exception.status_code.should eq HTTP::Status::INTERNAL_SERVER_ERROR
  end
end
