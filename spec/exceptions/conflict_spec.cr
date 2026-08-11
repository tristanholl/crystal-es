require "../spec_helper"

describe ES::Exception::Conflict do
  it "defaults to 'Conflict' at 400" do
    exception = ES::Exception::Conflict.new

    exception.message.should eq("Conflict")
    exception.status_code.should eq(HTTP::Status::BAD_REQUEST)
  end
end
