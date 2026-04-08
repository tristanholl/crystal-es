require "../spec_helper"

class TestProjection < ES::Projection
  getter collected : Array(UUID) = [] of UUID

  protected def apply(event : ES::Event)
    @collected << event.header.event_id
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
