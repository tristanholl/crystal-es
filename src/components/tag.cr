module ES
  # A tag on an event, in plaintext, as the application knows it.
  #
  # Tags are what a dynamic consistency boundary is drawn around: a query selects
  # every event carrying a given set of tags, rather than one aggregate's stream.
  # An event declares its tags with `tag` inside `define_event`; each one takes its
  # value from a body attribute.
  #
  # A tag is stored in the event header as `<key>:<value>`, or — when declared
  # `hashed: true` — as `<key>:<hmac>`, keyed by `ES::TagHasher`. The plaintext value
  # of a hashed tag never reaches the store.
  struct Tag
    getter key : String
    getter value : String
    getter? hashed : Bool

    def initialize(key : String | Symbol, value, @hashed : Bool = false)
      @key = key.to_s
      @value = value.to_s

      raise ES::Exception::InvalidState.new("Tag key must not be empty") if @key.empty?
      raise ES::Exception::InvalidState.new("Tag key '#{@key}' must not contain ':'") if @key.includes?(':')
      raise ES::Exception::InvalidState.new("Tag key must not contain a NUL byte") if @key.includes?('\0')
    end

    # The stored form of an unhashed tag. A hashed tag has no stored form without
    # a `ES::TagHasher`, so asking for one is refused rather than leaking the value.
    def plain : String
      raise ES::Exception::InvalidState.new("Tag '#{@key}' is hashed and has no plaintext stored form") if @hashed

      "#{@key}:#{@value}"
    end

    # Keeps the value of a hashed tag out of logs and exception messages
    def to_s(io : IO) : Nil
      io << @key << ':'
      if @hashed
        io << "[hashed]"
      else
        io << @value
      end
    end

    # :ditto:
    def inspect(io : IO) : Nil
      io << "ES::Tag("
      to_s(io)
      io << ')'
    end
  end
end
