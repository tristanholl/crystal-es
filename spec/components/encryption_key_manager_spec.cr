require "../spec_helper"

describe ES::EncryptionKeyManager do
  describe "#seal" do
    it "produces an envelope that keeps the plaintext out of the stored body" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "iban-of-a-real-person"
      )

      body = JSON.parse(encryption.seal(event))

      body.as_h.keys.sort.should eq(["ct", "iv", "tag"])
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

      JSON.parse(encryption.seal(event)).as_h.keys.sort.should eq(["ct", "iv", "tag"])
    end

    it "refuses to seal a destroyed key, so nothing lands under an erased key" do
      encryption = test_encryption
      key_id = encryption.create_key
      encryption.destroy_key(key_id)

      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "too late"
      )

      expect_raises(ES::Exception::NotFound) do
        encryption.seal(event)
      end
    end
  end

  describe "#open" do
    it "returns the body that was sealed" do
      encryption = test_encryption
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "recovered"
      )

      body = encryption.open(JSON.parse(encryption.seal(event)), event.header)

      body["secret"].as_s.should eq("recovered")
    end

    it "passes a plaintext body straight through" do
      encryption = test_encryption
      body = JSON.parse(%({"secret": "plain"}))

      returned = encryption.open(body, PlainEvent.new(actor_id: nil, command_handler: "handler", secret: "plain").header)

      returned.should eq(body)
    end

    it "raises NotFound once the key has been destroyed — the deletion is the answer" do
      encryption = test_encryption
      key_id = encryption.create_key
      event = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: key_id, secret: "to be erased"
      )
      envelope = JSON.parse(encryption.seal(event))

      encryption.destroy_key(key_id)

      expect_raises(ES::Exception::NotFound) do
        encryption.open(envelope, event.header)
      end
    end

    it "raises the same way when the key row was simply never created" do
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

    # The key id no longer travels as its own outer field to compare against the
    # header — it is folded into the binding digest instead (see `binding_digest`),
    # so naming a different key is indistinguishable from naming a different event:
    # the envelope was never sealed under the key this header points at, and
    # `PayloadCipher.open` rejects it on the HMAC tag before the digest is even
    # looked at.
    it "refuses to open an envelope under a header naming a different key than the one it was sealed under" do
      encryption = test_encryption
      sealed_under = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      )
      envelope = JSON.parse(encryption.seal(sealed_under))

      header_naming_another_key = EncryptedEvent.new(
        actor_id: nil, command_handler: "handler",
        encryption_key_id: encryption.create_key, secret: "secret"
      ).header

      expect_raises(ES::Exception::InvalidEventStream) do
        encryption.open(envelope, header_naming_another_key)
      end
    end

    # Discrimination between plaintext and encrypted bodies now lives entirely in
    # the header: there is no body-level marker left to sniff. A plaintext body
    # that merely happens to share field names with an envelope is not
    # distinguishable from a real one — the header settles it.
    it "treats a body as plaintext whenever the header names no key, even one shaped like an envelope" do
      encryption = test_encryption
      shaped_like_an_envelope = JSON.parse(%({"iv": "x", "ct": "y", "tag": "z"}))

      encryption.open(shaped_like_an_envelope, ES::Event::Header.new).should eq(shaped_like_an_envelope)
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
    it "removes the row, so a subsequent read raises NotFound" do
      encryption = test_encryption
      key_id = encryption.create_key

      encryption.destroy_key(key_id)

      expect_raises(ES::Exception::NotFound) do
        encryption.seal(EncryptedEvent.new(actor_id: nil, command_handler: "handler", encryption_key_id: key_id, secret: "secret"))
      end
    end

    it "is idempotent, so a repeated erasure request is harmless" do
      encryption = test_encryption
      key_id = encryption.create_key

      encryption.destroy_key(key_id)
      encryption.destroy_key(key_id)
    end
  end
end
