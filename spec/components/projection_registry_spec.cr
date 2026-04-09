require "../spec_helper"

class DummyProjection < ES::Projection
  @@handle = "dummy_projection"
  @@table = %("projections"."dummy")
end

class AnotherProjection < ES::Projection
  @@handle = "another_projection"

  def truncate_proxy
    self.truncate
  end
end

describe ES::ProjectionRegistry do
  it "registers handle" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    pr.projection_class("dummy_projection").should eq(DummyProjection)
  end

  it "raises Conflict if handle is already registered" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    expect_raises(ES::Exception::Conflict) do
      pr.register(DummyProjection)
    end
  end

  it "raises NotFound if handle is not registered" do
    pr = ES::ProjectionRegistry.new
    expect_raises(ES::Exception::NotFound) do
      pr.projection_class("unknown")
    end
  end

  it "returns true for registered? when handle is registered" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    pr.registered?("dummy_projection").should be_true
  end

  it "returns false for registered? when handle is not registered" do
    pr = ES::ProjectionRegistry.new
    pr.registered?("unknown").should be_false
  end

  it "lists all registered projection handles" do
    pr = ES::ProjectionRegistry.new
    pr.register(DummyProjection)
    pr.register(AnotherProjection)
    pr.all.should contain("dummy_projection")
    pr.all.should contain("another_projection")
    pr.all.size.should eq(2)
  end

  it "returns empty list when no projections are registered" do
    pr = ES::ProjectionRegistry.new
    pr.all.should be_empty
  end
end

describe ES::Projection do
  it "exposes handle class method" do
    DummyProjection.handle.should eq("dummy_projection")
  end

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
