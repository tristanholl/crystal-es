module ES
  module EventDSL
    macro attribute(name, type, default)
      # consumed by `define_event`
    end

    macro define_event(event_type, event_handle, encrypted = false)
      define_event({{event_type}}, {{event_handle}}, {{encrypted}}) do
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
      %}

      struct Body < ES::Event::Body
        {% for entry in entries %}
          getter {{ entry.args[0].id }} : {{ entry.args[1] }}
        {% end %}

        def initialize(
          @comment : String,
          {% for entry in entries %}
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
        {% for entry in entries %}
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
          {% for entry in entries %}
            {{ entry.args[0].id }}: {{ entry.args[0].id }},
          {% end %}
        )
      end
    end
  end
end
