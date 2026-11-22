module ES
  # One clause of an `ES::Query`: events of any of the given types that carry
  # *all* of the given tags.
  #
  # Leaving out the types matches events of every type; leaving out the tags
  # matches regardless of tags. An item with neither matches every event.
  #
  # ```
  # ES::QueryItem.new(StudentSubscribed, StudentUnsubscribed, tags: {course_id: course_id})
  # ES::QueryItem.new(tags: {student_email: email})
  # ```
  #
  # Tags are given in plaintext. Whether a value is hashed before it is matched
  # follows how its key is declared on the events (`tag :key, hashed: true`), so a
  # query never has to repeat that decision. A key no event declares is matched
  # as is.
  struct QueryItem
    # Event handles; empty means any type
    getter types : Array(String)

    # Tags an event must all carry; empty means any tags
    getter tags : Array(ES::Tag)

    # An item restricted to the given event types
    def initialize(*types : ES::Event.class, tags = NamedTuple.new)
      @types = [] of String
      types.each { |type| @types << type.handle }
      @tags = resolve_tags(tags)
    end

    # An item matching events of any type
    def initialize(*, tags = NamedTuple.new)
      @types = [] of String
      @tags = resolve_tags(tags)
    end

    private def resolve_tags(tags) : Array(ES::Tag)
      resolved = [] of ES::Tag
      tags.each do |key, value|
        # A nil attribute carries no tag, so there is nothing a query could match
        raise ES::Exception::InvalidState.new("Tag '#{key}' has no value to query by") if value.nil?

        resolved << ES::Tag.new(key, value, ES::Event.tag_key_hashed?(key.to_s))
      end
      resolved
    end
  end

  # Selects events by type and tag rather than by aggregate: the events that make
  # up a dynamic consistency boundary. An event matches when it matches any of the
  # items.
  #
  # ```
  # query = ES::Query.new(
  #   ES::QueryItem.new(CourseDefined, CourseCapacityChanged, tags: {course_id: course_id}),
  #   ES::QueryItem.new(StudentSubscribed, tags: {course_id: course_id}),
  # )
  # events = event_store.read(query)
  # ```
  struct Query
    getter items : Array(ES::QueryItem)

    # An empty query would be ambiguous — all events or none — so at least one
    # item is required, which the typed splat enforces at compile time.
    # `Query.all` is the query for every event.
    def initialize(*items : ES::QueryItem)
      @items = [] of ES::QueryItem
      items.each { |item| @items << item }
    end

    # A query matching every event
    def self.all : Query
      new(ES::QueryItem.new)
    end
  end
end

module ES
  # The consistency check of a conditional append: fail if an event matching the
  # query was appended after the given position.
  #
  # The usual shape is read, decide, append — with the same query and the
  # position of the last event the read returned:
  #
  # ```
  # events = store.read(query)
  # # ... decide on events ...
  # store.append([event], ES::AppendCondition.new(query, after: events.last?.try(&.position)))
  # ```
  #
  # `after` must be the position of the last event `read` returned for the same
  # query, or nil if it returned none. That read waits for in-flight appends it
  # could match, so no matching event can commit later with a lower position.
  # Positions are not commit-ordered, so a position taken from elsewhere — the
  # head of the store, a read of another query — can be past a matching event
  # that committed late, which the check would then not see.
  struct AppendCondition
    getter fail_if_events_match : ES::Query
    getter after : Int64?

    def initialize(@fail_if_events_match : ES::Query, @after : Int64? = nil)
      raise ES::Exception::InvalidState.new("after must not be negative, got #{after}") if after && after < 0
    end
  end
end
