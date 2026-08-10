require "../../spec_helper"

describe ES::KeyStoreAdapters::InMemory do
  it "returns the key it stored" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)

    key = store.fetch(id)

    key.id.should eq(id)
    key.encryption_private_key.should eq("wrapped".to_slice)
    key.application_encryption_key_id.should eq("v1")
    key.encryption_algorithm.should eq(ES::PayloadCipher::ALGORITHM)
  end

  it "reports an unknown key" do
    expect_raises(ES::Exception::NotFound) do
      ES::KeyStoreAdapters::InMemory.new.fetch(UUID.v7)
    end
  end

  it "removes the row entirely on destroy — the deletion is the erasure" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)

    store.destroy(id)

    expect_raises(ES::Exception::NotFound) do
      store.fetch(id)
    end
  end

  it "is idempotent, so a repeated erasure request is harmless" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)

    store.destroy(id)
    store.destroy(id)
  end
end
