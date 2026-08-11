require "../../spec_helper"

describe ES::QueueAdapters::Postgres do
  pending "setup creates the pgmq schema, extension, and per-queue trigger", tags: "db" do
  end

  pending "setup is a noop when the pgmq extension already exists", tags: "db" do
  end

  pending "read returns messages sent to the queue", tags: "db" do
  end

  pending "archive marks a message read", tags: "db" do
  end

  pending "delete removes a message from the queue", tags: "db" do
  end
end
