require "../spec_helper"

class DummyProjection < ES::Projection
  @@table = %("projections"."dummy")
end

class AnotherProjection < ES::Projection
  def truncate_proxy
    self.truncate
  end
end

describe ES::ProjectionRegistry do
  it "registers a projection class" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    pr.registered?(DummyProjection).should be_true
  end

  it "raises Conflict if the same class is registered twice" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    expect_raises(ES::Exception::Conflict) do
      pr.register(DummyProjection)
    end
  end

  it "returns false for registered? when class is not registered" do
    pr = ES::ProjectionRegistry.new
    pr.registered?(DummyProjection).should be_false
  end

  it "lists all registered projection classes" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    pr.register(AnotherProjection)
    pr.all.should contain(DummyProjection)
    pr.all.should contain(AnotherProjection)
    pr.all.size.should eq(2)
  end

  it "returns empty list when no projections are registered" do
    pr = ES::ProjectionRegistry.new
    pr.all.should be_empty
  end
end

describe ES::Projection do
  it "exposes table class method" do
    DummyProjection.table.should eq(%("projections"."dummy"))
  end

  it "truncate raises NotImplemented when no table is defined" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    db = DBMock.open

    projection = AnotherProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    expect_raises(ES::Exception::NotImplemented) do
      projection.truncate_proxy
    end
  end
end
