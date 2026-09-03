require "../spec_helper"

describe ES::Exception::SchemaDrift do
  it "exposes what was given through getters" do
    changes = [
      ES::ProjectionMeta::SchemaChange.new(severity: "breaking", kind: "column_removed", description: "column \"amount\" was removed"),
    ]

    exception = ES::Exception::SchemaDrift.new(
      projection_class: "Ledger",
      table_name: "finance.ledger",
      stored_fingerprint: "abc123",
      compiled_fingerprint: "def456",
      changes: changes,
    )

    exception.projection_class.should eq("Ledger")
    exception.table_name.should eq("finance.ledger")
    exception.stored_fingerprint.should eq("abc123")
    exception.compiled_fingerprint.should eq("def456")
    exception.changes.should eq(changes)
    exception.status_code.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
  end

  it "builds a message naming the projection, the table, both fingerprints, and every change" do
    changes = [
      ES::ProjectionMeta::SchemaChange.new(severity: "breaking", kind: "column_removed", description: "column \"amount\" was removed"),
      ES::ProjectionMeta::SchemaChange.new(severity: "non_breaking", kind: "index_added", description: "index \"idx_amount\" was added"),
    ]

    exception = ES::Exception::SchemaDrift.new(
      projection_class: "Ledger",
      table_name: "finance.ledger",
      stored_fingerprint: "abc123",
      compiled_fingerprint: "def456",
      changes: changes,
    )

    message = exception.message.should_not be_nil

    message.should contain("Ledger")
    message.should contain("finance.ledger")
    message.should contain("abc123")
    message.should contain("def456")
    message.should contain("[breaking] column_removed: column \"amount\" was removed")
    message.should contain("[non_breaking] index_added: index \"idx_amount\" was added")
  end
end
