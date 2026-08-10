require "../spec_helper"

private def with_env(values : Hash(String, String?), &)
  previous = values.keys.to_h { |k| {k, ENV[k]?} }

  values.each do |key, value|
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  yield
ensure
  previous.try &.each do |key, value|
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end

private def encoded_key : String
  Base64.strict_encode(ES::PayloadCipher.random_key)
end

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

  it "reads the key from the environment as raw base64" do
    key = ES::PayloadCipher.random_key

    with_env({ES::ApplicationEncryptionKeyManager::ENV_VARIABLE => Base64.strict_encode(key)}) do
      manager = ES::ApplicationEncryptionKeyManager.from_env

      manager.key_id.should eq(Digest::SHA256.hexdigest(key))
    end
  end

  it "reports an unset environment variable" do
    with_env({ES::ApplicationEncryptionKeyManager::ENV_VARIABLE => nil}) do
      expect_raises(ES::Exception::DependencyUnavailable) do
        ES::ApplicationEncryptionKeyManager.from_env
      end
    end
  end

  it "rejects a value that is not valid base64" do
    with_env({ES::ApplicationEncryptionKeyManager::ENV_VARIABLE => "not-base64!!"}) do
      expect_raises(ES::Exception::InvalidState) do
        ES::ApplicationEncryptionKeyManager.from_env
      end
    end
  end
end
