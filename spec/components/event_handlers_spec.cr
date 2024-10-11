require "../spec_helper"

describe ES::EventHandlers do
  it "registers handle" do
    eh = ES::EventHandlers.new
    eh.register(DummyEvent)
    eh.event_class("dummy").should eq(DummyEvent)
  end

  it "raises exception if handle is not registered" do
    eh = ES::EventHandlers.new
    eh.register(DummyEvent)
    expect_raises(ES::Exception::NotFound) do
      eh.event_class("unknown")
    end
  end
end
