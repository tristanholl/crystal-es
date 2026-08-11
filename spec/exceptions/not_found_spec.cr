require "../spec_helper"

describe ES::Exception::NotFound do
  it "defaults to 'Resource not found' at 400" do
    exception = ES::Exception::NotFound.new

    exception.message.should eq("Resource not found")
    exception.status_code.should eq(HTTP::Status::BAD_REQUEST)
  end
end
