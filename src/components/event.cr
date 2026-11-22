module ES
  abstract class Event
    @@type = "AbstractAggregate"
    @@handle = "Abstract"

    # Default header struct of the event
    struct Header
      include JSON::Serializable

      getter actor_id : UUID? = nil
      getter aggregate_id : UUID = UUID.v7
      getter aggregate_type : String = "undefined"
      getter aggregate_version : Int32 = 1
      getter command_handler : String = "undefined"
      getter command_handler_version : String = ES::Config.version
      getter created_at : Time = Time.utc
      getter encryption_key_id : UUID? = nil
      getter event_handle : String = "undefined"
      getter event_id : UUID = UUID.v7
      getter event_version : String = "1.0.0"

      # Tags in their stored form — `<key>:<value>`, or `<key>:<hmac>` for a
      # hashed tag. Empty on an event that has not been stored yet: the event
      # store derives them from `ES::Event#tags` on append, because only the store
      # holds the key a hashed tag needs. Headers written before tags existed carry
      # no field and read back as empty, and an untagged header is written without
      # one, so its JSON is unchanged from before tags existed.
      @[JSON::Field(ignore_serialize: tags.empty?)]
      getter tags : Array(String) = [] of String

      # Default constructor
      def initialize; end

      def initialize(
        @actor_id : UUID?,
        @aggregate_id : UUID,
        @aggregate_version : Int32,
        @event_handle : String,
        @event_version = "1.0.0",
        @created_at = Time.utc,
        @aggregate_type = "undefined",
        @command_handler = "undefined",
        @command_handler_version = ES::Config.version,
        @encryption_key_id : UUID? = nil,
        @tags : Array(String) = [] of String,
      )
      end

      # Returns a copy of this header carrying the given stored tags
      def with_tags(tags : Array(String)) : Header
        copy = dup
        copy.tags = tags
        copy
      end

      # A method rather than `setter tags : Array(String)`: re-declaring the typed
      # instance variable would drop the JSON::Field annotation on `tags`.
      protected def tags=(@tags : Array(String))
      end
    end

    # Default body struct of the event
    abstract struct Body
      include JSON::Serializable

      getter comment = ""
    end

    getter header : Header
    getter body : Body

    # Returns aggregate the event belongs to
    def self.aggregate
      @@type
    end

    # Returns the event handle
    def self.handle
      @@handle
    end

    # Whether the body of this event must be encrypted before it is stored.
    #
    # Declared per event class rather than decided per call, so which events carry
    # protected data is greppable and visible in review. `define_event(encrypted:
    # true)` overrides this and makes `encryption_key_id` a required constructor
    # argument, which is what stops a handler quietly writing plaintext. An
    # undeclared event's constructor has no `encryption_key_id` parameter at all,
    # so passing one there is a compile error rather than a per-instance opt-in.
    def self.encrypted? : Bool
      false
    end

    # The tags of this event, in plaintext. `define_event` generates this from its
    # `tag` declarations; an event without any has none.
    def tags : Array(ES::Tag)
      [] of ES::Tag
    end

    # The declared tags of this event class as `{key, hashed}` pairs
    def self.tag_definitions : Array({String, Bool})
      [] of {String, Bool}
    end

    # A query hashes a tag value according to how the key is declared, so a key
    # hashed by one event and stored in the clear by another would make queries
    # miss events. Keeping the two consistent is the application's job; this
    # only warns at compile time when they diverge, comparing every event class
    # `define_event` generated, whether it is registered or not.
    macro finished
      {% seen = {} of StringLiteral => ASTNode %}
      {% for klass in ES::Event.all_subclasses.sort_by(&.name) %}
        {% if klass.has_constant?("TAG_DEFINITIONS") %}
          {% for definition in klass.constant("TAG_DEFINITIONS") %}
            {% previous = seen[definition[0]] %}
            {% if previous && previous[1] != definition[1] %}
              {% warning "Tag '#{definition[0].id}' is declared hashed: #{previous[1]} in #{previous[2]} but hashed: #{definition[1]} in #{klass}. Queries hash a tag by its declaration, so one of the two will not be found." %}
            {% end %}
            {% seen[definition[0]] = {definition[0], definition[1], klass} unless previous %}
          {% end %}
        {% end %}
      {% end %}
    end

    def initialize
      @header = ES::Event::Header.new
      @body = ES::Event::Body.new
    end
  end
end
