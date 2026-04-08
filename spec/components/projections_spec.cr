require "../spec_helper"

class DummyProjection < ES::Projection
  @@handle = "dummy_projection"
  @@table = %("projections"."dummy")
end

class AnotherProjection < ES::Projection
  @@handle = "another_projection"
end

describe ES::Projections do
  it "registers handle" do
    ph = ES::Projections.new
    ph.register(DummyProjection)
    ph.projection_class("dummy_projection").should eq(DummyProjection)
  end

  it "raises Conflict if handle is already registered" do
    ph = ES::Projections.new
    ph.register(DummyProjection)
    expect_raises(ES::Exception::Conflict) do
      ph.register(DummyProjection)
    end
  end

  it "raises NotFound if handle is not registered" do
    ph = ES::Projections.new
    expect_raises(ES::Exception::NotFound) do
      ph.projection_class("unknown")
    end
  end

  it "returns true for registered? when handle is registered" do
    ph = ES::Projections.new
    ph.register(DummyProjection)
    ph.registered?("dummy_projection").should be_true
  end

  it "returns false for registered? when handle is not registered" do
    ph = ES::Projections.new
    ph.registered?("unknown").should be_false
  end

  it "lists all registered projection handles" do
    ph = ES::Projections.new
    ph.register(DummyProjection)
    ph.register(AnotherProjection)
    ph.all.should contain("dummy_projection")
    ph.all.should contain("another_projection")
    ph.all.size.should eq(2)
  end

  it "returns empty list when no projections are registered" do
    ph = ES::Projections.new
    ph.all.should be_empty
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
      projection.truncate
    end
  end
end
