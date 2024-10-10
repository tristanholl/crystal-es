require "../spec_helper"

describe ES::Exception::NotFound do
  it "should initialize with a message" do
    exception = ES::Exception::NotFound.new("Test message")
    exception.message.should eq "Test message"
  end

  it "should initialize with a default message" do
    exception = ES::Exception::NotFound.new
    exception.message.should eq "Resource not found"
  end

  it "should initialize with a status code" do
    exception = ES::Exception::NotFound.new(status_code: HTTP::Status::SERVICE_UNAVAILABLE)
    exception.status_code.should eq HTTP::Status::SERVICE_UNAVAILABLE
  end

  it "should initialize with a default status code" do
    exception = ES::Exception::NotFound.new
    exception.status_code.should eq HTTP::Status::BAD_REQUEST
  end
end
