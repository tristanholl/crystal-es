require "../spec_helper"

describe ES::PayloadCipher do
  it "returns the plaintext it was given" do
    key = ES::PayloadCipher.random_key
    sealed = ES::PayloadCipher.seal(key, "the quick brown fox".to_slice)

    String.new(ES::PayloadCipher.open(key, sealed)).should eq("the quick brown fox")
  end

  it "generates keys of the size the cipher expects" do
    ES::PayloadCipher.random_key.size.should eq(ES::PayloadCipher::KEY_SIZE)
  end

  it "produces a different ciphertext each time the same plaintext is sealed" do
    key = ES::PayloadCipher.random_key
    first = ES::PayloadCipher.seal(key, "same".to_slice)
    second = ES::PayloadCipher.seal(key, "same".to_slice)

    first.iv.should_not eq(second.iv)
    first.ciphertext.should_not eq(second.ciphertext)
  end

  it "rejects a key of the wrong size" do
    expect_raises(ES::Exception::InvalidState) do
      ES::PayloadCipher.seal(Bytes.new(16), "payload".to_slice)
    end
  end

  it "refuses to open with the wrong key" do
    sealed = ES::PayloadCipher.seal(ES::PayloadCipher.random_key, "payload".to_slice)

    expect_raises(ES::Exception::InvalidEventStream) do
      ES::PayloadCipher.open(ES::PayloadCipher.random_key, sealed)
    end
  end

  it "detects a modified ciphertext" do
    key = ES::PayloadCipher.random_key
    sealed = ES::PayloadCipher.seal(key, "payload that is long enough to span a block".to_slice)
    sealed.ciphertext[0] ^= 0xff_u8

    expect_raises(ES::Exception::InvalidEventStream) do
      ES::PayloadCipher.open(key, sealed)
    end
  end

  it "detects a modified iv" do
    key = ES::PayloadCipher.random_key
    sealed = ES::PayloadCipher.seal(key, "payload".to_slice)
    sealed.iv[0] ^= 0xff_u8

    expect_raises(ES::Exception::InvalidEventStream) do
      ES::PayloadCipher.open(key, sealed)
    end
  end

  it "detects a modified tag" do
    key = ES::PayloadCipher.random_key
    sealed = ES::PayloadCipher.seal(key, "payload".to_slice)
    sealed.tag[0] ^= 0xff_u8

    expect_raises(ES::Exception::InvalidEventStream) do
      ES::PayloadCipher.open(key, sealed)
    end
  end

  it "survives a pack and unpack round trip" do
    key = ES::PayloadCipher.random_key
    sealed = ES::PayloadCipher.seal(key, "payload spanning more than a single cipher block".to_slice)

    unpacked = ES::PayloadCipher.unpack(ES::PayloadCipher.pack(sealed))

    unpacked.iv.should eq(sealed.iv)
    unpacked.tag.should eq(sealed.tag)
    unpacked.ciphertext.should eq(sealed.ciphertext)
    String.new(ES::PayloadCipher.open(key, unpacked)).should eq("payload spanning more than a single cipher block")
  end

  it "rejects a packed payload too short to hold an iv and a tag" do
    expect_raises(ES::Exception::InvalidState) do
      ES::PayloadCipher.unpack(Bytes.new(ES::PayloadCipher::IV_SIZE + ES::PayloadCipher::TAG_SIZE))
    end
  end
end
