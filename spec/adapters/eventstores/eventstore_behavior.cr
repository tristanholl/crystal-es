# Shared examples for the conditional append semantics (Dynamic Consistency Boundaries).
# Include them in an adapter spec via `eventstore_dcb_examples(->{ MyStore.new })` so every
# event store implementation enforces the same behavior.
macro eventstore_dcb_examples(factory)
  it "appends a batch of events atomically" do
    store = {{ factory }}.call
    aggregate_id = UUID.v7
    e1 = DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 1)
    e2 = DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 2)

    store.append([e1, e2] of ES::Event)

    store.fetch_events(aggregate_id).size.should eq(2)
    store.last_version(aggregate_id.to_s).should eq(2)
  end

  it "tracks tag sequences independently of the primary aggregate" do
    store = {{ factory }}.call
    tag = "course:#{UUID.v7}"
    e1 = DummyEvent.new(aggregate_version: 1, tags: {tag => 1})
    e2 = DummyEvent.new(aggregate_version: 1, tags: {tag => 2})

    store.append(e1)
    store.append(e2)

    store.last_version(tag).should eq(2)
    store.fetch_events(tag).size.should eq(2)
  end

  it "fetch_events(tag) returns the tag stream ordered by tag version" do
    store = {{ factory }}.call
    tag = "course:#{UUID.v7}"
    e1 = DummyEvent.new(aggregate_version: 1, tags: {tag => 1})
    e2 = DummyEvent.new(aggregate_version: 1, tags: {tag => 2})
    e3 = DummyEvent.new(aggregate_version: 1, tags: {tag => 3})

    store.append(e1)
    store.append(e2)
    store.append(e3)

    events = store.fetch_events(tag)
    events.map { |e| e.header["tags"][tag].as_i }.should eq([1, 2, 3])
  end

  it "accepts an append when the condition matches the current versions" do
    store = {{ factory }}.call
    tag = "course:#{UUID.v7}"
    store.append(DummyEvent.new(aggregate_version: 1, tags: {tag => 1}))

    event = DummyEvent.new(aggregate_version: 1, tags: {tag => 2})
    store.append([event] of ES::Event, ES::AppendCondition.new({tag => 1}))

    store.last_version(tag).should eq(2)
  end

  it "accepts an append conditioned on an empty sequence (expected version 0)" do
    store = {{ factory }}.call
    tag = "course:#{UUID.v7}"

    event = DummyEvent.new(aggregate_version: 1, tags: {tag => 1})
    store.append([event] of ES::Event, ES::AppendCondition.new({tag => 0}))

    store.last_version(tag).should eq(1)
  end

  it "rejects an append when a condition sequence advanced" do
    store = {{ factory }}.call
    tag = "course:#{UUID.v7}"
    store.append(DummyEvent.new(aggregate_version: 1, tags: {tag => 1}))

    # A competing append advances the tag sequence
    store.append(DummyEvent.new(aggregate_version: 1, tags: {tag => 2}))

    stale = DummyEvent.new(aggregate_version: 1, tags: {tag => 2})
    expect_raises(ES::Exception::Conflict) do
      store.append([stale] of ES::Event, ES::AppendCondition.new({tag => 1}))
    end
  end

  it "rejects an append when a read-only condition member advanced" do
    store = {{ factory }}.call
    tag = "course:#{UUID.v7}"
    store.append(DummyEvent.new(aggregate_version: 1, tags: {tag => 1}))

    # The event does not write to the tag sequence, the condition only asserts it
    event = DummyEvent.new(aggregate_version: 1)
    expect_raises(ES::Exception::Conflict) do
      store.append([event] of ES::Event, ES::AppendCondition.new({tag => 0}))
    end
  end

  it "rejects non-contiguous versions within a written sequence" do
    store = {{ factory }}.call
    aggregate_id = UUID.v7
    store.append(DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 1))

    gap = DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 3)
    expect_raises(ES::Exception::Conflict) do
      store.append(gap)
    end
  end

  it "rejects a duplicate version within a written sequence" do
    store = {{ factory }}.call
    aggregate_id = UUID.v7
    store.append(DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 1))

    duplicate = DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 1)
    expect_raises(ES::Exception::Conflict) do
      store.append(duplicate)
    end
  end

  it "rejects the whole batch if any event conflicts" do
    store = {{ factory }}.call
    aggregate_id = UUID.v7
    tag = "course:#{UUID.v7}"
    store.append(DummyEvent.new(aggregate_version: 1, tags: {tag => 1}))

    e1 = DummyEvent.new(aggregate_id: aggregate_id, aggregate_version: 1)
    e2 = DummyEvent.new(aggregate_version: 1, tags: {tag => 1}) # duplicate tag version

    expect_raises(ES::Exception::Conflict) do
      store.append([e1, e2] of ES::Event)
    end

    store.fetch_events(aggregate_id).should be_empty
    store.last_version(aggregate_id.to_s).should eq(0)
  end

  it "last_version returns 0 for unknown sequences" do
    store = {{ factory }}.call
    store.last_version("unknown:sequence").should eq(0)
  end
end
