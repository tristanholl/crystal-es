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

describe ES::ApplicationKeyRing do
  it "unwraps what it wrapped" do
    ring = test_key_ring
    data_key = ES::PayloadCipher.random_key

    application_key_id, wrapped = ring.wrap(data_key)

    application_key_id.should eq("v1")
    ring.unwrap(application_key_id, wrapped).should eq(data_key)
  end

  it "never stores the data key in the clear" do
    ring = test_key_ring
    data_key = ES::PayloadCipher.random_key

    _, wrapped = ring.wrap(data_key)

    wrapped.should_not eq(data_key)
    String.new(wrapped).includes?(String.new(data_key)).should be_false
  end

  it "wraps under the current key while still unwrapping older ones" do
    ring = test_key_ring(["v1", "v2"], current: "v2")
    data_key = ES::PayloadCipher.random_key

    application_key_id, wrapped = ring.wrap(data_key)

    application_key_id.should eq("v2")
    ring.unwrap("v2", wrapped).should eq(data_key)
  end

  it "reports an application key that is not in the ring" do
    ring = test_key_ring
    _, wrapped = ring.wrap(ES::PayloadCipher.random_key)

    expect_raises(ES::Exception::DependencyUnavailable) do
      ring.unwrap("absent", wrapped)
    end
  end

  it "rejects a current key that is not in the ring" do
    expect_raises(ES::Exception::InvalidState) do
      ES::ApplicationKeyRing.new({"v1" => ES::PayloadCipher.random_key}, "v2")
    end
  end

  it "rejects an empty ring" do
    expect_raises(ES::Exception::InvalidState) do
      ES::ApplicationKeyRing.new(Hash(String, Bytes).new, "v1")
    end
  end

  it "rejects a key of the wrong size" do
    expect_raises(ES::Exception::InvalidState) do
      ES::ApplicationKeyRing.new({"v1" => Bytes.new(16)}, "v1")
    end
  end

  it "reads a single key from the environment without needing a current key named" do
    with_env({ES::ApplicationKeyRing::ENV_KEYS => "v1:#{encoded_key}", ES::ApplicationKeyRing::ENV_CURRENT => nil}) do
      ring = ES::ApplicationKeyRing.from_env

      ring.current_id.should eq("v1")
      ring.key_ids.should eq(["v1"])
    end
  end

  it "reads several keys from the environment" do
    with_env({ES::ApplicationKeyRing::ENV_KEYS => "v1:#{encoded_key}, v2:#{encoded_key}", ES::ApplicationKeyRing::ENV_CURRENT => "v2"}) do
      ring = ES::ApplicationKeyRing.from_env

      ring.current_id.should eq("v2")
      ring.key_ids.should eq(["v1", "v2"])
    end
  end

  it "demands a current key when the ring holds more than one" do
    with_env({ES::ApplicationKeyRing::ENV_KEYS => "v1:#{encoded_key},v2:#{encoded_key}", ES::ApplicationKeyRing::ENV_CURRENT => nil}) do
      expect_raises(ES::Exception::InvalidState) do
        ES::ApplicationKeyRing.from_env
      end
    end
  end

  it "reports an unset environment variable" do
    with_env({ES::ApplicationKeyRing::ENV_KEYS => nil}) do
      expect_raises(ES::Exception::DependencyUnavailable) do
        ES::ApplicationKeyRing.from_env
      end
    end
  end

  it "rejects a malformed entry" do
    with_env({ES::ApplicationKeyRing::ENV_KEYS => encoded_key, ES::ApplicationKeyRing::ENV_CURRENT => nil}) do
      expect_raises(ES::Exception::InvalidState) do
        ES::ApplicationKeyRing.from_env
      end
    end
  end
end
