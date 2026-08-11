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

  it "raises Conflict when the same handle is registered twice" do
    eh = ES::EventHandlers.new
    eh.register(DummyEvent)

    expect_raises(ES::Exception::Conflict) do
      eh.register(DummyEvent)
    end
  end

  describe "#registered?" do
    it "reports true for a registered handle" do
      eh = ES::EventHandlers.new
      eh.register(DummyEvent)

      eh.registered?("dummy").should be_true
    end

    it "reports false for an unknown handle" do
      ES::EventHandlers.new.registered?("unknown").should be_false
    end
  end
end
