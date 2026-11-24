require "../spec_helper"

describe ES::Exception::StaleCheckpoint do
  it "is a conflict at 409" do
    exception = ES::Exception::StaleCheckpoint.new

    exception.should be_a(ES::Exception::Conflict)
    exception.message.should eq("Subscription position moved meanwhile")
    exception.status_code.should eq(HTTP::Status::CONFLICT)
  end
end
