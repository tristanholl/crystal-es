require "../spec_helper"

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
