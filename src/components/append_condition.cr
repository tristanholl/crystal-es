module ES
  # The consistency check of a conditional append: the given tags must still be
  # at the given versions.
  #
  # Every tag has a version in the event store: the number of events appended
  # carrying it. Each tagged event raises the version of each of its tags by
  # one, and the store stamps the new value into its header
  # (`header.tag_versions`).
  # Versions of one tag are gap-free and follow commit order — two appends
  # carrying the same tag never run at once — so "the tag is still at version 7"
  # means exactly "nothing carrying this tag was appended since". Positions,
  # which are not commit-ordered, play no part in it.
  #
  # The versions usually come from a decision read:
  #
  # ```
  # decision = store.read_for_decision(query)
  # # ... decide on decision.events ...
  # store.append([event], decision.condition)
  # ```
  #
  # They can also come from anywhere that saw the stored events, such as a
  # projection, since every stored event carries its tag versions. A decision
  # taken on eventually consistent data is then guarded by the versions that
  # data reflected:
  #
  # ```
  # ES::AppendCondition.new
  #   .expect(:user_id, user_id, version: 7)
  #   .expect(:organization_id, organization_id, version: 3)
  # ```
  #
  # Version 0 means the tag was never used, which is how a uniqueness rule is
  # written. A tag counts every event carrying it, whatever its type and other
  # tags, so the check is deliberately coarse: any change to an expected tag
  # fails it.
  struct AppendCondition
    # Expected versions of tags given in plaintext, encoded by the store
    getter tags : Array({ES::Tag, Int64})

    # Expected versions of tags given in their stored form
    getter stored_tags : Array({String, Int64})

    def initialize
      @tags = [] of {ES::Tag, Int64}
      @stored_tags = [] of {String, Int64}
    end

    protected def initialize(@tags : Array({ES::Tag, Int64}), @stored_tags : Array({String, Int64}))
    end

    # Expects a tag, given in plaintext, at a version. Whether the value is
    # hashed follows how the key is declared on the events, as in a query.
    #
    # The key must be declared by some event: a key nothing carries would
    # always be at version 0, so a misspelt key would silently pass.
    def expect(key : Symbol | String, value, version : Int)
      raise ES::Exception::InvalidState.new("Tag '#{key}' has no value to expect a version of") if value.nil?
      raise ES::Exception::InvalidState.new("Tag '#{key}' is not declared by any event") unless ES::Event.tag_key_declared?(key.to_s)

      tag = ES::Tag.new(key, value, ES::Event.tag_key_hashed?(key.to_s))
      AppendCondition.new(@tags + [{tag, checked_version(key, version)}], @stored_tags)
    end

    # Expects a tag, given in its stored form — as found in `header.tags` and
    # `header.tag_versions` — at a version. This is what a projection holds.
    #
    # Checked like a stored tag on an event: the key must be declared, and a key
    # declared hashed must hold a digest. Otherwise a plaintext value could reach
    # the store under a hashed key, and a check would pass against a tag no
    # event carries. Messages name the key only, never the value.
    def expect_stored(tag : String, version : Int)
      key, separator, value = tag.partition(':')
      raise ES::Exception::InvalidState.new("A stored tag has the form '<key>:<value>'") if separator.empty? || key.empty?
      raise ES::Exception::InvalidState.new("Tag '#{key}' is not declared by any event") unless ES::Event.tag_key_declared?(key)
      raise ES::Exception::InvalidState.new("Tag '#{key}' is declared hashed but the stored tag holds no digest") if ES::Event.tag_key_hashed?(key) && !value.matches?(ES::TagHasher::STORED_DIGEST)

      AppendCondition.new(@tags, @stored_tags + [{tag, checked_version(key, version)}])
    end

    # Whether the condition expects nothing, making the append unconditional
    def empty? : Bool
      @tags.empty? && @stored_tags.empty?
    end

    private def checked_version(key, version : Int) : Int64
      raise ES::Exception::InvalidState.new("Version of tag '#{key}' must not be negative, got #{version}") if version < 0
      version.to_i64
    end
  end

  # What a decision was taken on: the events a query returned, and the version
  # of each of the query's tags at that moment, read together so that they
  # agree. `condition` turns those versions into the check its append needs, so
  # the read and the condition cannot drift apart.
  struct Decision
    getter events : Array(ES::EventStore::Event)

    # Stored tag to version, as of the read
    getter versions : Hash(String, Int64)

    def initialize(@events : Array(ES::EventStore::Event), @versions : Hash(String, Int64))
    end

    # The condition under which nothing this decision depended on has changed
    def condition : AppendCondition
      @versions.reduce(AppendCondition.new) { |condition, (tag, version)| condition.expect_stored(tag, version) }
    end
  end
end
