require "../../spec_helper"

describe ES::EventStoreAdapters::Postgres do
  pending "last_event_id returns nil when the store is empty", tags: "db" do
  end

  pending "last_event_id returns the most recently appended event's id", tags: "db" do
  end

  pending "setup creates the event_tags table and backfills primary-aggregate memberships", tags: "db" do
  end

  pending "append inserts one event_tags row per sequence membership", tags: "db" do
  end

  pending "append raises a conflict when a condition sequence advanced", tags: "db" do
  end

  pending "append raises a conflict when a read-only condition member advanced concurrently", tags: "db" do
  end

  pending "append rejects non-contiguous versions within a written sequence", tags: "db" do
  end

  pending "append rolls back the whole batch on conflict", tags: "db" do
  end

  pending "append translates unique violations (SQLSTATE 23505) into a conflict", tags: "db" do
  end

  pending "fetch_events(tag) returns the tag stream ordered by tag version", tags: "db" do
  end

  pending "last_version returns 0 for unknown sequences", tags: "db" do
  end
end
