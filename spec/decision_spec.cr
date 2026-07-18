require "./spec_helper"

describe ES::Decision do
  describe ".accept" do
    it "holds the provided events" do
      events = [DummyEvent.new, DummyEvent.new]
      d = ES::Decision(ES::Event).accept(events)
      d.accepted?.should be_true
      d.rejected?.should be_false
      d.events.should eq(events)
    end

    it "raises when reason is requested on an Accepted decision" do
      d = ES::Decision(ES::Event).accept([] of ES::Event)
      expect_raises(Exception) { d.reason }
    end
  end

  describe ".reject" do
    it "holds the provided reason" do
      d = ES::Decision(ES::Event).reject("over limit")
      d.rejected?.should be_true
      d.accepted?.should be_false
      d.reason.should eq("over limit")
    end

    it "returns an empty events array on a Rejected decision" do
      d = ES::Decision(ES::Event).reject("nope")
      d.events.should eq([] of ES::Event)
    end
  end

  describe "equality" do
    it "two Accepted decisions with equal events are equal" do
      e = DummyEvent.new
      a = ES::Decision(ES::Event).accept([e])
      b = ES::Decision(ES::Event).accept([e])
      a.should eq(b)
    end

    it "two Accepted decisions with different events are not equal" do
      a = ES::Decision(ES::Event).accept([DummyEvent.new])
      b = ES::Decision(ES::Event).accept([DummyEvent.new])
      a.should_not eq(b)
    end

    it "two Rejected decisions with the same reason are equal" do
      a = ES::Decision(ES::Event).reject("reason")
      b = ES::Decision(ES::Event).reject("reason")
      a.should eq(b)
    end

    it "two Rejected decisions with different reasons are not equal" do
      a = ES::Decision(ES::Event).reject("a")
      b = ES::Decision(ES::Event).reject("b")
      a.should_not eq(b)
    end

    it "Accepted and Rejected are not equal" do
      a = ES::Decision(ES::Event).accept([] of ES::Event)
      b = ES::Decision(ES::Event).reject("nope")
      a.should_not eq(b)
    end
  end

  it "preserves the type parameter" do
    d = ES::Decision(DummyEvent).accept([DummyEvent.new])
    d.events.first.should be_a(DummyEvent)
  end
end
