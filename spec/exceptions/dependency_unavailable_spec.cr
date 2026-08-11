require "../spec_helper"

describe ES::Exception::DependencyUnavailable do
  it "defaults to 'Dependency unavailable' at 500" do
    exception = ES::Exception::DependencyUnavailable.new

    exception.message.should eq("Dependency unavailable")
    exception.status_code.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
  end
end
