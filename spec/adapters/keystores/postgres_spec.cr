require "../../spec_helper"

# These need a live database, like the other Postgres adapter specs. The
# behaviour they would cover is exercised against the in-memory keystore in
# `in_memory_spec.cr`; what is left here is the SQL itself.
describe ES::KeyStoreAdapters::Postgres do
  pending "setup creates the encryption_keys table", tags: "db" do
  end

  pending "setup is a noop when the table already exists", tags: "db" do
  end

  pending "create stores a wrapped key and returns its id", tags: "db" do
  end

  pending "fetch raises NotFound for an unknown key", tags: "db" do
  end

  pending "destroy nulls the material and stamps destroyed_at", tags: "db" do
  end

  pending "destroy keeps the original destroyed_at when called twice", tags: "db" do
  end

  pending "each_live skips destroyed keys", tags: "db" do
  end

  pending "rewrap leaves a destroyed key untouched", tags: "db" do
  end
end

describe ES::KeyStore::Key do
  it "reports a destroyed key" do
    ES::KeyStore::Key.new(
      encryption_key_id: UUID.v7,
      encrypted_encryption_key: nil,
      application_encryption_key_id: "v1",
      destroyed_at: Time.utc,
    ).destroyed?.should be_true
  end

  it "reports a live key" do
    ES::KeyStore::Key.new(
      encryption_key_id: UUID.v7,
      encrypted_encryption_key: "wrapped".to_slice,
      application_encryption_key_id: "v1",
    ).destroyed?.should be_false
  end
end
