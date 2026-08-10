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

  pending "destroy removes the row", tags: "db" do
  end

  pending "destroy is a noop for an already-removed row", tags: "db" do
  end
end
