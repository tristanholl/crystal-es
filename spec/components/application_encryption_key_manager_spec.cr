require "../spec_helper"

describe ES::ApplicationEncryptionKeyManager do
  it "unwraps what it wrapped" do
    manager = test_application_key
    data_key = ES::PayloadCipher.random_key

    wrapped = manager.wrap(data_key)

    manager.unwrap(manager.key_id, wrapped).should eq(data_key)
  end

  it "never stores the data key in the clear" do
    manager = test_application_key
    data_key = ES::PayloadCipher.random_key

    wrapped = manager.wrap(data_key)

    wrapped.should_not eq(data_key)
    String.new(wrapped).includes?(String.new(data_key)).should be_false
  end

  it "derives the key id from the key's own bytes" do
    key = ES::PayloadCipher.random_key

    ES::ApplicationEncryptionKeyManager.new(key).key_id.should eq(Digest::SHA256.hexdigest(key))
  end

  it "gives the same key the same id every time" do
    key = ES::PayloadCipher.random_key

    ES::ApplicationEncryptionKeyManager.new(key).key_id.should eq(ES::ApplicationEncryptionKeyManager.new(key).key_id)
  end

  it "gives different keys different ids" do
    ES::ApplicationEncryptionKeyManager.new(ES::PayloadCipher.random_key).key_id.should_not eq(
      ES::ApplicationEncryptionKeyManager.new(ES::PayloadCipher.random_key).key_id
    )
  end

  it "refuses to unwrap under a key id that does not match its own — a configuration fault, not a missing key" do
    manager = test_application_key
    wrapped = manager.wrap(ES::PayloadCipher.random_key)

    expect_raises(ES::Exception::DependencyUnavailable) do
      manager.unwrap("some-other-key-id", wrapped)
    end
  end

  it "rejects a key of the wrong size" do
    expect_raises(ES::Exception::InvalidState) do
      ES::ApplicationEncryptionKeyManager.new(Bytes.new(16))
    end
  end

  it "accepts key material decoded by the application from wherever it is configured" do
    key = ES::PayloadCipher.random_key
    encoded = Base64.strict_encode(key)

    # Stands in for an application reading APPLICATION_ENCRYPTION_KEYS (or any
    # other source) itself — the library never touches ENV.
    manager = ES::ApplicationEncryptionKeyManager.new(Base64.decode(encoded))

    manager.key_id.should eq(Digest::SHA256.hexdigest(key))
  end
end
