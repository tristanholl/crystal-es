module ES
  # Authenticated encryption for event bodies and for the data keys themselves.
  #
  # AES-256-CBC with an encrypt-then-MAC HMAC-SHA256 tag, rather than AES-GCM.
  # That is a deliberate compromise: Crystal's `OpenSSL::Cipher` gained
  # `gcm_tag`/`gcm_tag=` only after 1.17, and released versions bind neither those
  # nor `EVP_CIPHER_CTX_ctrl`, so reaching GCM would mean reopening a stdlib class
  # to get at its private context. Encrypt-then-MAC gets the same properties —
  # confidentiality plus tamper detection — out of API that has been stable for
  # years, and keeps this shard working on the Crystal versions `shard.yml` claims.
  #
  # One data key comes in; two independent subkeys are derived from it, so the same
  # bytes never both encrypt and authenticate.
  #
  # Ciphertexts are *not* bound to their context here. Callers that need that must
  # carry the binding inside the plaintext — see `ES::Encryption#binding_digest`.
  module PayloadCipher
    ALGORITHM = "aes-256-cbc-hmac-sha256"
    CIPHER    = "aes-256-cbc"
    KEY_SIZE  = 32
    IV_SIZE   = 16
    TAG_SIZE  = 32

    ENCRYPTION_SUBKEY = "crystal-es:v1:encryption"
    MAC_SUBKEY        = "crystal-es:v1:authentication"

    # An encrypted payload and the two values needed to read it back
    struct Sealed
      getter iv : Bytes
      getter ciphertext : Bytes
      getter tag : Bytes

      def initialize(@iv : Bytes, @ciphertext : Bytes, @tag : Bytes)
      end
    end

    # Returns a fresh 256 bit key from a cryptographically secure source
    def self.random_key : Bytes
      Random::Secure.random_bytes(KEY_SIZE)
    end

    # Encrypts the plaintext under the given key with a fresh random IV, then
    # authenticates the IV and ciphertext together
    def self.seal(key : Bytes, plaintext : Bytes) : Sealed
      verify_key_size(key)

      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.encrypt
      cipher.key = encryption_subkey(key)
      iv = cipher.random_iv

      io = IO::Memory.new
      io.write(cipher.update(plaintext))
      io.write(cipher.final)
      ciphertext = io.to_slice

      Sealed.new(iv, ciphertext, tag(key, iv, ciphertext))
    end

    # Authenticates and then decrypts a sealed payload.
    #
    # The tag is checked before anything is decrypted, so a modified ciphertext,
    # IV or tag is rejected without the cipher ever touching it. A wrong key fails
    # the same check. There is no path that returns unauthenticated plaintext.
    def self.open(key : Bytes, sealed : Sealed) : Bytes
      verify_key_size(key)

      expected = tag(key, sealed.iv, sealed.ciphertext)
      raise ES::Exception::InvalidEventStream.new("Authenticated decryption failed: the payload was modified or the wrong key was used") unless Crypto::Subtle.constant_time_compare(expected, sealed.tag)

      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.decrypt
      cipher.key = encryption_subkey(key)
      cipher.iv = sealed.iv

      io = IO::Memory.new
      io.write(cipher.update(sealed.ciphertext))
      io.write(cipher.final)
      io.to_slice
    rescue OpenSSL::Cipher::Error
      raise ES::Exception::InvalidEventStream.new("Authenticated decryption failed: the payload could not be decrypted")
    end

    # Packs a sealed payload into a single byte string as `iv || tag || ciphertext`,
    # for storage in a column that holds one blob rather than three
    def self.pack(sealed : Sealed) : Bytes
      io = IO::Memory.new
      io.write(sealed.iv)
      io.write(sealed.tag)
      io.write(sealed.ciphertext)
      io.to_slice
    end

    # Reverses `pack`
    def self.unpack(packed : Bytes) : Sealed
      raise ES::Exception::InvalidState.new("Packed payload is too short to be valid") if packed.size <= IV_SIZE + TAG_SIZE

      Sealed.new(
        packed[0, IV_SIZE].dup,
        packed[(IV_SIZE + TAG_SIZE)..].dup,
        packed[IV_SIZE, TAG_SIZE].dup,
      )
    end

    # Authenticates the IV alongside the ciphertext, so neither can be swapped
    private def self.tag(key : Bytes, iv : Bytes, ciphertext : Bytes) : Bytes
      io = IO::Memory.new
      io.write(iv)
      io.write(ciphertext)

      OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, mac_subkey(key), io.to_slice)
    end

    private def self.encryption_subkey(key : Bytes) : Bytes
      OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, ENCRYPTION_SUBKEY)
    end

    private def self.mac_subkey(key : Bytes) : Bytes
      OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, MAC_SUBKEY)
    end

    private def self.verify_key_size(key : Bytes)
      raise ES::Exception::InvalidState.new("#{ALGORITHM} requires a #{KEY_SIZE} byte key, got #{key.size}") if key.size != KEY_SIZE
    end
  end
end
