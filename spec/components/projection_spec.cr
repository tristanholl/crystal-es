require "../spec_helper"

class TestProjectIfEmptyProjection < ES::Projection
  @@init = true
  @@projection_batch_size = 1_i64
  getter collected : Array(UUID) = [] of UUID

  protected def table_empty? : Bool
    true
  end

  protected def apply(event : ES::Event)
    @collected << event.header.event_id
  end
end

class TestProjectNotEmptyProjection < ES::Projection
  @@init = true
  getter collected : Array(UUID) = [] of UUID

  protected def table_empty? : Bool
    false
  end

  protected def apply(event : ES::Event)
    @collected << event.header.event_id
  end
end

class TestProjectIfEmptyDisabledProjection < ES::Projection
  getter collected : Array(UUID) = [] of UUID

  protected def table_empty? : Bool
    true
  end

  protected def apply(event : ES::Event)
    @collected << event.header.event_id
  end
end

class TestProjection < ES::Projection
  getter collected : Array(UUID) = [] of UUID

  protected def apply(event : ES::Event)
    @collected << event.header.event_id
  end
end

class TestApplyDSLProjection < ES::Projection
  include ES::ProjectionDSL

  getter last_header : ES::Event::Header? = nil
  getter last_aggregate_id : UUID? = nil
  getter last_aggregate_version : Int32? = nil
  getter last_created_at : Time? = nil
  getter last_body : DummyEvent::Body? = nil

  apply(DummyEvent) do
    @last_header = header
    @last_aggregate_id = aggregate_id
    @last_aggregate_version = aggregate_version
    @last_created_at = created_at
    @last_body = body
  end
end

describe ES::Projection do
  it "replay yields all events to the projection" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    e1 = DummyEvent.new
    e2 = DummyEvent.new
    e3 = DummyEvent.new
    store.append(e1)
    store.append(e2)
    store.append(e3)

    projection = TestProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.replay(truncate: true)

    projection.collected.should eq([e1.header.event_id, e2.header.event_id, e3.header.event_id])
  end

  it "replay stops at until_event_id (inclusive)" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    e1 = DummyEvent.new
    e2 = DummyEvent.new
    e3 = DummyEvent.new
    store.append(e1)
    store.append(e2)
    store.append(e3)

    projection = TestProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.replay(truncate: true, until_event_id: e2.header.event_id)

    projection.collected.should eq([e1.header.event_id, e2.header.event_id])
  end

  it "replay silently skips events with unregistered handles" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    # DummyEvent is NOT registered — all events should be skipped
    db = DBMock.open

    e1 = DummyEvent.new
    e2 = DummyEvent.new
    store.append(e1)
    store.append(e2)

    projection = TestProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.replay(truncate: true)

    projection.collected.should be_empty
  end

  it "replay raises NotFound for unknown until_event_id" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    db = DBMock.open

    expect_raises(ES::Exception::NotFound) do
      projection = TestProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
      projection.replay(truncate: true, until_event_id: UUID.v7)
    end
  end

  it "replay raises InvalidState when truncate is false" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    db = DBMock.open

    expect_raises(ES::Exception::InvalidState) do
      projection = TestProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
      projection.replay(truncate: false)
    end
  end
end

describe "ES::Projection#init" do
  it "replays all events in the store when table is empty and init? is true" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    e1 = DummyEvent.new
    e2 = DummyEvent.new
    store.append(e1)
    store.append(e2)

    projection = TestProjectIfEmptyProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.init
    Fiber.yield

    projection.collected.should eq([e1.header.event_id, e2.header.event_id])
  end

  it "does not replay when table is not empty" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    store.append(DummyEvent.new)

    projection = TestProjectNotEmptyProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.init
    Fiber.yield

    projection.collected.should be_empty
  end

  it "does not replay when init? is false" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    store.append(DummyEvent.new)

    projection = TestProjectIfEmptyDisabledProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.init
    Fiber.yield

    projection.collected.should be_empty
  end

  it "does not replay when the store is empty" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    projection = TestProjectIfEmptyProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.init
    Fiber.yield

    projection.collected.should be_empty
  end

  it "stops at the horizon captured before spawning, ignoring events appended afterwards" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    handlers.register(DummyEvent)
    db = DBMock.open

    e1 = DummyEvent.new
    e2 = DummyEvent.new
    e3 = DummyEvent.new
    store.append(e1)
    store.append(e2)
    # e3 is appended after init captures the horizon — it must NOT be replayed
    projection = TestProjectIfEmptyProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.init
    store.append(e3)
    Fiber.yield

    projection.collected.should eq([e1.header.event_id, e2.header.event_id])
  end

  it "skips unregistered event handles during catch-up" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    # DummyEvent not registered
    db = DBMock.open

    store.append(DummyEvent.new)

    projection = TestProjectIfEmptyProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.init
    Fiber.yield

    projection.collected.should be_empty
  end
end

describe "ES::Projection.projection_batch_size" do
  it "defaults to 1000" do
    TestProjection.projection_batch_size.should eq(1000_i64)
  end

  it "reflects the configured value" do
    TestProjectIfEmptyProjection.projection_batch_size.should eq(1_i64)
  end
end

describe "ES::ProjectionDSL apply macro" do
  it "pre-binds header, aggregate_id, aggregate_version, created_at and body" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    db = DBMock.open
    event = DummyEvent.new
    projection = TestApplyDSLProjection.new(event_handlers: handlers, event_store: store, projection_database: db)
    projection.call(event)

    projection.last_header.should eq(event.header)
    projection.last_aggregate_id.should eq(event.header.aggregate_id)
    projection.last_aggregate_version.should eq(event.header.aggregate_version)
    projection.last_created_at.should eq(event.header.created_at)
    projection.last_body.should be_a(DummyEvent::Body)
  end
end

# Mixes a hand-written typed overload with one generated by the DSL macro
class TestMixedDeclarationProjection < ES::Projection
  include ES::ProjectionDSL

  def apply(event : DummyEvent)
  end

  apply(OtherDummyEvent) do
  end
end

describe "ES::Projection.handles?" do
  it "detects hand-written and DSL-generated apply overloads alike" do
    TestMixedDeclarationProjection.handles?(DummyEvent).should be_true
    TestMixedDeclarationProjection.handles?(OtherDummyEvent).should be_true
  end

  it "reports false for an event the projection declares no apply for" do
    TestApplyDSLProjection.handles?(DummyEvent).should be_true
    TestApplyDSLProjection.handles?(OtherDummyEvent).should be_false
  end

  it "treats a projection overriding the ES::Event catch-all as handling everything" do
    # TestProjection deliberately overrides `apply(event : ES::Event)`
    TestProjection.handles?(DummyEvent).should be_true
    TestProjection.handles?(OtherDummyEvent).should be_true
  end
end
