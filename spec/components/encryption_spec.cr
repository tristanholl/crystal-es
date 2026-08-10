require "../spec_helper"

describe ES::Encryption do
  describe "#seal" do
    it "produces an envelope that keeps the plaintext out of the stored body" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "iban-of-a-real-person"
      )

      body = JSON.parse(encryption.seal(event))

      body[ES::Encryption::ENVELOPE_MARKER].should eq(ES::Encryption::ENVELOPE_FORMAT)
      body["alg"].as_s.should eq(ES::PayloadCipher::ALGORITHM)
      body["kid"].as_s.should eq(event.header.encryption_key_id.to_s)
      body.to_json.includes?("iban-of-a-real-person").should be_false
    end

    it "leaves a body without a key alone" do
      encryption = test_encryption
      event = PlainEvent.new(actor_id: nil, command_handler: "handler", secret: "not a secret")

      JSON.parse(encryption.seal(event))["secret"].as_s.should eq("not a secret")
    end

    it "encrypts an undeclared event that names a key anyway" do
      encryption = test_encryption
      event = PlainEvent.new(
        actor_id: nil, command_handler: "handler",
        secret: "opted in", encryption_key_id: encryption.create_key
      )

      ES::Encryption.envelope?(JSON.parse(encryption.seal(event))).should be_true
    end
  end

  describe "#open" do
    it "returns the body that was sealed" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "recovered"
      )

      body, shredded = encryption.open(JSON.parse(encryption.seal(event)), event.header)

      shredded.should be_false
      body["secret"].as_s.should eq("recovered")
    end

    it "passes a plaintext body straight through" do
      encryption = test_encryption
      body = JSON.parse(%({"secret": "plain"}))

      returned, shredded = encryption.open(body, PlainEvent.new(actor_id: nil, command_handler: "handler", secret: "plain").header)

      shredded.should be_false
      returned.should eq(body)
    end

    it "reports a destroyed key rather than raising" do
      encryption = test_encryption
      key_id = encryption.create_key
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "to be erased"
      )
      envelope = JSON.parse(encryption.seal(event))

      encryption.destroy_key(key_id)
      body, shredded = encryption.open(envelope, event.header)

      shredded.should be_true
      body.as_h.should be_empty
    end

    it "raises when the key row is missing entirely, which is not an erasure" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )
      envelope = JSON.parse(encryption.seal(event))

      expect_raises(ES::Exception::NotFound) do
        test_encryption.open(envelope, event.header)
      end
    end

    it "refuses an envelope transplanted onto another event under the same key" do
      encryption = test_encryption
      key_id = encryption.create_key

      donor = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "belongs to the donor"
      )
      recipient = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "belongs to the recipient"
      )

      expect_raises(ES::Exception::InvalidEventStream) do
        encryption.open(JSON.parse(encryption.seal(donor)), recipient.header)
      end
    end

    it "refuses an envelope whose key disagrees with the header" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )

      envelope = JSON.parse(encryption.seal(event)).as_h
      envelope["kid"] = JSON::Any.new(UUID.v7.to_s)

      expect_raises(ES::Exception::InvalidEventStream) do
        encryption.open(JSON::Any.new(envelope), event.header)
      end
    end

    it "refuses an encrypted body whose header names no key" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )
      envelope = JSON.parse(encryption.seal(event))

      expect_raises(ES::Exception::InvalidEventStream) do
        encryption.open(envelope, ES::Event::Header.new)
      end
    end

    it "detects a modified ciphertext" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )

      envelope = JSON.parse(encryption.seal(event)).as_h
      tampered = Base64.decode(envelope["ct"].as_s)
      tampered[0] ^= 0xff_u8
      envelope["ct"] = JSON::Any.new(Base64.strict_encode(tampered))

      expect_raises(ES::Exception::InvalidEventStream) do
        encryption.open(JSON::Any.new(envelope), event.header)
      end
    end
  end

  describe "#destroy_key" do
    it "marks the key destroyed" do
      encryption = test_encryption
      key_id = encryption.create_key

      encryption.destroyed?(key_id).should be_false
      encryption.destroy_key(key_id)
      encryption.destroyed?(key_id).should be_true
    end

    it "makes the key unusable for new events, so nothing lands under an erased key" do
      encryption = test_encryption
      key_id = encryption.create_key
      encryption.destroy_key(key_id)

      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "too late"
      )

      expect_raises(ES::Exception::KeyDestroyed) do
        encryption.seal(event)
      end
    end

    it "is idempotent, so a repeated erasure request is harmless" do
      encryption = test_encryption
      key_id = encryption.create_key

      encryption.destroy_key(key_id)
      encryption.destroy_key(key_id)

      encryption.destroyed?(key_id).should be_true
    end
  end

  describe "#rewrap_all" do
    it "moves live keys onto the current application key without disturbing the bodies" do
      key_store = ES::KeyStoreAdapters::InMemory.new
      keys = {"v1" => ES::PayloadCipher.random_key, "v2" => ES::PayloadCipher.random_key}

      encryption = ES::Encryption.new(key_store, ES::ApplicationKeyRing.new(keys, "v1"))
      key_id = encryption.create_key
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "survives rotation"
      )
      envelope = JSON.parse(encryption.seal(event))

      key_store.fetch(key_id).application_encryption_key_id.should eq("v1")

      # A fresh instance so nothing is served out of the data key cache
      rotated = ES::Encryption.new(key_store, ES::ApplicationKeyRing.new(keys, "v2"))
      rotated.rewrap_all.should eq(1)

      key_store.fetch(key_id).application_encryption_key_id.should eq("v2")
      rotated.open(envelope, event.header)[0]["secret"].as_s.should eq("survives rotation")
    end

    it "leaves keys already on the current application key alone" do
      encryption = test_encryption
      encryption.create_key

      encryption.rewrap_all.should eq(0)
    end

    it "skips destroyed keys" do
      key_store = ES::KeyStoreAdapters::InMemory.new
      keys = {"v1" => ES::PayloadCipher.random_key, "v2" => ES::PayloadCipher.random_key}

      encryption = ES::Encryption.new(key_store, ES::ApplicationKeyRing.new(keys, "v1"))
      encryption.destroy_key(encryption.create_key)

      ES::Encryption.new(key_store, ES::ApplicationKeyRing.new(keys, "v2")).rewrap_all.should eq(0)
    end
  end

  describe ".envelope?" do
    it "recognises an envelope" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )

      ES::Encryption.envelope?(JSON.parse(encryption.seal(event))).should be_true
    end

    it "does not mistake a plain body for one" do
      ES::Encryption.envelope?(JSON.parse(%({"secret": "plain"}))).should be_false
      ES::Encryption.envelope?(JSON.parse(%([1, 2, 3]))).should be_false
    end
  end
end
