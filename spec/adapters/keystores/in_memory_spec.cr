require "../../spec_helper"

describe ES::KeyStoreAdapters::InMemory do
  it "returns the key it stored" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)

    key = store.fetch(id)

    key.encryption_key_id.should eq(id)
    key.material.should eq("wrapped".to_slice)
    key.application_encryption_key_id.should eq("v1")
    key.algorithm.should eq(ES::PayloadCipher::ALGORITHM)
    key.destroyed?.should be_false
  end

  it "reports an unknown key" do
    expect_raises(ES::Exception::NotFound) do
      ES::KeyStoreAdapters::InMemory.new.fetch(UUID.v7)
    end
  end

  it "keeps a tombstone when a key is destroyed, so an erasure is distinguishable from a missing row" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)

    store.destroy(id)
    key = store.fetch(id)

    key.destroyed?.should be_true
    key.destroyed_at.should_not be_nil
    key.encrypted_encryption_key.should be_nil
  end

  it "refuses to hand out the material of a destroyed key" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)
    store.destroy(id)

    expect_raises(ES::Exception::KeyDestroyed) do
      store.fetch(id).material
    end
  end

  it "yields only live keys" do
    store = ES::KeyStoreAdapters::InMemory.new
    live = store.create("live".to_slice, "v1", ES::PayloadCipher::ALGORITHM)
    destroyed = store.create("destroyed".to_slice, "v1", ES::PayloadCipher::ALGORITHM)
    store.destroy(destroyed)

    seen = [] of UUID
    store.each_live { |key| seen << key.encryption_key_id }

    seen.should eq([live])
  end

  it "replaces the wrapping of a live key" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)

    store.rewrap(id, "rewrapped".to_slice, "v2")
    key = store.fetch(id)

    key.material.should eq("rewrapped".to_slice)
    key.application_encryption_key_id.should eq("v2")
  end

  it "refuses to rewrap a destroyed key, which would resurrect it" do
    store = ES::KeyStoreAdapters::InMemory.new
    id = store.create("wrapped".to_slice, "v1", ES::PayloadCipher::ALGORITHM)
    store.destroy(id)

    expect_raises(ES::Exception::KeyDestroyed) do
      store.rewrap(id, "rewrapped".to_slice, "v2")
    end
  end
end
