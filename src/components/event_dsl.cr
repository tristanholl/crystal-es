module ES
  module EventDSL
    macro attribute(name, type, default)
      # consumed by `define_event`
    end

    macro tag(name, hashed = false)
      # consumed by `define_event`
    end

    macro define_event(event_type, event_handle, encrypted = false)
      define_event({{ event_type }}, {{ event_handle }}, {{ encrypted }}) do
      end
    end

    # Declares an event.
    #
    # `encrypted: true` marks the body as protected: the generated constructor then
    # *requires* an `encryption_key_id`, so the event cannot be built without naming
    # the key its body will be sealed under. The key itself is chosen by the caller
    # at construction, which is what allows one aggregate's events to sit under
    # several keys.
    #
    # `encrypted` left at its default has no `encryption_key_id` parameter at all —
    # passing one to an event that doesn't declare `encrypted: true` is a compile
    # error, not a silent per-instance opt-in.
    #
    # `tag :attribute` puts the attribute's value on the event as a tag, which is
    # what a dynamic consistency boundary is queried by. `hashed: true` stores a
    # keyed digest instead of the value (see `ES::TagHasher`); the default is to
    # store the value as is. A tag must name an attribute declared in the same
    # block, and a nil value carries no tag.
    #
    # ```
    # define_event("course", "student_subscribed") do
    #   attribute :course_id, UUID
    #   attribute :student_email, String
    #   tag :course_id
    #   tag :student_email, hashed: true
    # end
    # ```
    macro define_event(event_type, event_handle, encrypted = false, &block)
      @@type = {{ event_type }}
      @@handle = {{ event_handle }}

      def self.encrypted? : Bool
        {{ encrypted }}
      end

      {%
        entries = if block.nil? || block.body.nil?
                    [] of String
                  elsif block.body.is_a?(Expressions)
                    block.body.expressions
                  else
                    [block.body]
                  end

        attributes = [] of Call
        tags = [] of Call
        entries.each do |entry|
          if entry.is_a?(Call) && entry.name == "attribute"
            attributes << entry
          elsif entry.is_a?(Call) && entry.name == "tag"
            tags << entry
          else
            entry.raise "define_event only accepts `attribute` and `tag` declarations, got: #{entry}"
          end
        end

        tag_definitions = [] of TupleLiteral
        tags.each do |entry|
          entry.raise "tag takes exactly one attribute name, e.g. `tag :course_id`" if entry.args.size != 1
          name = entry.args[0]
          entry.raise "tag expects a symbol naming an attribute, got: #{name}" unless name.is_a?(SymbolLiteral)

          hashed = false
          (entry.named_args || [] of NamedArgument).each do |arg|
            if arg.name.stringify == "hashed"
              arg.raise "tag :#{name.id} expects `hashed:` to be true or false, got: #{arg.value}" unless arg.value.is_a?(BoolLiteral)
              hashed = arg.value
            else
              arg.raise "tag :#{name.id} has an unknown option '#{arg.name}'; the only option is `hashed:`"
            end
          end

          entry.raise "tag :#{name.id} does not name an attribute of this event" unless attributes.any? { |attribute| attribute.args[0].id == name.id }
          entry.raise "tag :#{name.id} is declared twice" if tag_definitions.any? { |definition| definition[0] == name.id.stringify }

          tag_definitions << {name.id.stringify, hashed}
        end
      %}

      {% unless tag_definitions.empty? %}
        # Read by the compile-time consistency check in `ES::Event`
        TAG_DEFINITIONS = [
          {% for definition in tag_definitions %}
            { {{ definition[0] }}, {{ definition[1] }} },
          {% end %}
        ] of {String, Bool}

        def self.tag_definitions : Array({String, Bool})
          TAG_DEFINITIONS.dup
        end

        def tags : Array(ES::Tag)
          tags = [] of ES::Tag
          body = @body.as(Body)
          {% for definition in tag_definitions %}
            %value = body.{{ definition[0].id }}
            tags << ES::Tag.new({{ definition[0] }}, %value, {{ definition[1] }}) unless %value.nil?
          {% end %}
          tags
        end
      {% end %}

      struct Body < ES::Event::Body
        {% for entry in attributes %}
          getter {{ entry.args[0].id }} : {{ entry.args[1] }}
        {% end %}

        def initialize(
          @comment : String,
          {% for entry in attributes %}
            {% if entry.args.size == 3 %}
              @{{ entry.args[0].id }} : {{ entry.args[1] }} = {{ entry.args[2] }},
            {% else %}
              @{{ entry.args[0].id }} : {{ entry.args[1] }},
            {% end %}
          {% end %}
        ); end
      end

      def initialize(@header : ES::Event::Header, body : JSON::Any)
        @body = Body.from_json(body.to_json)
      end

      def initialize(
        actor_id : UUID?,
        command_handler : String,
        {% if encrypted %}
          encryption_key_id : UUID,
        {% end %}
        {% for entry in attributes %}
          {% if entry.args.size == 3 %}
            {{ entry.args[0].id }} : {{ entry.args[1] }} = {{ entry.args[2] }},
          {% else %}
            {{ entry.args[0].id }} : {{ entry.args[1] }},
          {% end %}

        {% end %}
        comment = "",
        aggregate_id = UUID.v7,
        aggregate_version : Int32 = 1,
      )
        @header = Header.new(
          actor_id: actor_id,
          aggregate_id: aggregate_id,
          aggregate_type: @@type,
          aggregate_version: aggregate_version,
          command_handler: command_handler,
          encryption_key_id: {% if encrypted %} encryption_key_id {% else %} nil {% end %},
          event_handle: @@handle
        )
        @body = Body.new(
          comment: comment,
          {% for entry in attributes %}
            {{ entry.args[0].id }}: {{ entry.args[0].id }},
          {% end %}
        )
      end
    end
  end
end
