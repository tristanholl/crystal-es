module ES
  # Turns the value of a `hashed: true` tag into a keyed digest before it is stored.
  #
  # The digest is an HMAC-SHA256 under a key derived from the application
  # encryption key, never a plain hash: tag values worth hashing — email addresses,
  # names — have so little entropy that an unkeyed digest falls to a dictionary
  # attack against a database dump within seconds. Keyed, the dump alone is not
  # enough.
  #
  # What this does not do: make the value anonymous. The same value always yields
  # the same digest — that is what lets a query find it — so whoever holds the
  # application key can still test whether a known value appears in the store. A
  # hashed tag is pseudonymous data, and unlike an encrypted body it survives
  # crypto-shredding. Tag by a surrogate id (a UUID) where you can; hash the tags
  # where you cannot.
  #
  # Hashing is opt-in: unhashed tags need nothing configured, and appending an
  # event with a hashed tag fails while no hasher is configured.
  #
  # ```
  # ES::Config.tag_hasher = ES::TagHasher.new(application_key)
  # ```
  #
  # The derived key cannot be rotated: every stored digest depends on it, and a
  # new key would make queries miss every event written under the old one. It is
  # tied to the application key, which carries the same constraint already.
  class TagHasher
    # Derivation label for the tag key. The version keeps a future change of
    # scheme from silently matching digests written under this one.
    KEY_LABEL = "crystal-es:v1:tags"

    # Bytes of the HMAC kept. 128 bits make an accidental collision negligible,
    # and a collision could only ever cause a false match, never hide an event.
    DIGEST_SIZE = 16

    # What `encode` stores for a hashed tag's value
    STORED_DIGEST = /\A[0-9a-f]{#{DIGEST_SIZE * 2}}\z/

    def initialize(application_key : ES::ApplicationEncryptionKeyManager)
      @key = application_key.derive_key(KEY_LABEL)
    end

    # Keeps the key out of logs and error reports. Anyone holding it can run the
    # dictionary attack the HMAC exists to prevent.
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << ">"
    end

    # :ditto:
    def to_s(io : IO) : Nil
      inspect(io)
    end

    # Returns the stored form of a tag: `<key>:<hex digest>` when hashed,
    # `<key>:<value>` otherwise.
    #
    # The key is part of the HMAC input, so the same value under two keys —
    # `email:x` and `username:x` — produces unrelated digests and cannot be linked.
    # The NUL separator cannot occur in a key, which keeps `("a", "b\0c")` and
    # `("a\0b", "c")` apart.
    def encode(tag : ES::Tag) : String
      return tag.plain unless tag.hashed?

      digest = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, @key, "#{tag.key}\0#{tag.value}")
      "#{tag.key}:#{digest[0, DIGEST_SIZE].hexstring}"
    end
  end
end
