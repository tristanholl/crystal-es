require "../../spec_helper"

describe ES::EventStoreAdapters::Postgres do
  pending "setup creates events_event_id_idx on a fresh database", tags: "db" do
  end

  pending "setup creates events_event_id_idx on an existing events table without it", tags: "db" do
  end

  pending "setup is a noop when run twice", tags: "db" do
  end

  pending "fetch_event uses events_event_id_idx (EXPLAIN with enable_seqscan off)", tags: "db" do
  end

  pending "last_event_id returns nil when the store is empty", tags: "db" do
  end

  pending "last_event_id returns the most recently appended event's id", tags: "db" do
  end
end
