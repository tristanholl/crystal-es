module ES
  # One question a decision asks of the event store, answered by folding the
  # events of a dynamic consistency boundary into a state.
  #
  # A decision projection declares the events it handles and the tags they must
  # carry. Its query is derived from those declarations, so the events a decision
  # reads and the events its fold expects can never drift apart, and neither can
  # the append condition, which comes from the same query. Several small
  # projections compose into one decision through
  # `ES::EventStore#build_decision_model`, which reads them all in one snapshot.
  #
  # ```
  # class CourseCapacity < ES::DecisionProjection(Int32?)
  #   def initialize(@course_id : UUID); end
  #
  #   def initial_state : State
  #     nil
  #   end
  #
  #   tags course_id: @course_id
  #
  #   on CourseDefined do |_state, _event|
  #     body.capacity
  #   end
  # end
  #
  # model = event_store.build_decision_model(capacity: CourseCapacity.new(course_id))
  # model.state[:capacity] # => Int32?
  # event_store.append([event], model.condition)
  # ```
  #
  # - `State` is the projection's state type, the type argument of
  #   `ES::DecisionProjection`. `initial_state` must return a fresh value on every
  #   call: a fold starts from it, so a shared mutable value would carry one
  #   decision's state into the next.
  # - `on EventClass do |state, event| ... end` handles one event class and
  #   returns the next state. The block also sees `body`, the event's body cast
  #   to its class. Keep handlers pure: a fold may run again on a retry.
  # - `tags key: value, ...` names the tags every handled event must carry, as
  #   in `ES::QueryItem`. Values may refer to instance variables. Each handled
  #   event class must declare every key, or it could never match.
  # - `on_erased EventClass do |state, header| ... end` handles an event of a
  #   class handled with `on` whose body was erased with its encryption key. The
  #   header (type, tags) is still there. Without it, folding such an event
  #   raises `ES::Exception::InvalidState` rather than skip it, since a decision
  #   taken on silently missing events would be wrong. A body also comes back
  #   erased when its key is missing from the key store for any other reason,
  #   such as a misconfigured key store, so a handler can't tell the two apart.
  #
  # Every one of these is checked at compile time.
  abstract class DecisionProjection(S)
    # The state the fold starts from
    abstract def initial_state : S

    # The tags given with `tags`, in plaintext
    abstract def tag_filter

    # The query item selecting this projection's events: its handled event
    # classes, carrying all of its tags
    abstract def query_item : ES::QueryItem

    # Applies one stored event, which must match `query_item`. Generated.
    abstract def apply_stored(state : S, stored : ES::EventStore::Event) : S

    # :nodoc:
    #
    # Folds events into a state, in the order given. Only the event class is
    # checked here — an unhandled one raises `ES::Exception::InvalidState` — not
    # the tags, which need the store's tag encoding. Selecting the events that
    # match `query_item` is `ES::EventStore#build_decision_model`'s job: folding
    # unfiltered events, such as all of a decision read's, silently counts
    # events of other boundaries.
    def fold(events : Enumerable(ES::EventStore::Event)) : S
      events.reduce(initial_state) { |state, stored| apply_stored(state, stored) }
    end

    # Names the class and its tag keys only. A projection holds the plaintext
    # values of its tags, which for a hashed tag must stay out of logs.
    def to_s(io : IO) : Nil
      io << self.class.name << '(' << tag_filter.keys.join(", ") << ')'
    end

    # :ditto:
    def inspect(io : IO) : Nil
      to_s(io)
    end

    macro inherited
      # The state type, so handlers and `initial_state` can name it
      alias State = {{ @type.superclass.type_vars.first }}

      # Filled by `on`, `on_erased` and `tags`, read once the class is complete
      DECISION_HANDLED = [] of Nil
      DECISION_ERASED = [] of Nil
      DECISION_TAGS = [] of Nil

      macro finished
        \{%
          handled = DECISION_HANDLED
          erased = DECISION_ERASED
          declared_tags = DECISION_TAGS
        %}
        \{% unless @type.abstract? %}
          \{%
            raise "#{@type} handles no events; declare at least one `on EventClass do |state, event| ... end`" if handled.empty?
            raise "#{@type} names no tags; declare `tags key: value`. A decision read needs tags to detect a change" if declared_tags.empty?
            declared_tags[1].raise "#{@type} declares `tags` twice; name every tag in one `tags` call" if declared_tags.size > 1

            keys = declared_tags[0].keys.map(&.stringify)
            handled.each_with_index do |type, index|
              klass = type.resolve
              type.raise "#{@type} handles #{type}, which is not an ES::Event" unless klass < ::ES::Event
              type.raise "#{@type} handles #{type} twice" if handled[0...index].any? { |other| other.resolve == klass }

              definitions = klass.has_constant?("TAG_DEFINITIONS") ? klass.constant("TAG_DEFINITIONS").map { |definition| definition[0] } : [] of StringLiteral
              keys.each do |key|
                type.raise "#{@type} filters on tag :#{key.id}, which #{type} does not declare, so no #{type} could ever match" unless definitions.includes?(key)
              end
            end

            erased.each_with_index do |type, index|
              type.raise "#{@type} declares on_erased #{type} without `on #{type}`; a decision reads only the classes handled with `on`" unless handled.any? { |other| other.resolve == type.resolve }
              type.raise "#{@type} declares on_erased #{type} twice" if erased[0...index].any? { |other| other.resolve == type.resolve }
            end
          %}

          def query_item : ::ES::QueryItem
            ::ES::QueryItem.new(\{{ handled.splat }}, tags: tag_filter)
          end

          def apply_stored(state : State, stored : ::ES::EventStore::Event) : State
            header = ::ES::Event::Header.from_json(stored.header.to_json)
            \{% for type in handled %}
              if header.event_handle == \{{ type }}.handle
                if stored.body_erased?
                  \{% if erased.any? { |other| other.resolve == type.resolve } %}
                    return apply_erased_event(state, header, \{{ type }})
                  \{% else %}
                    raise ::ES::Exception::InvalidState.new("#{self.class.name} cannot fold event '#{header.event_id}': its body was erased with its encryption key; declare `on_erased \{{ type }}` to decide on it anyway")
                  \{% end %}
                end
                return apply_event(state, \{{ type }}.new(header, stored.body))
              end
            \{% end %}
            raise ::ES::Exception::InvalidState.new("#{self.class.name} does not handle '#{header.event_handle}'")
          end
        \{% end %}
      end
    end

    # Handles one event class: the block takes the state and the event and
    # returns the next state. `body` is the event's body, cast to its class.
    macro on(event_type, &block)
      {% event_type.raise "on #{event_type} expects a block taking |state, event|" unless block && block.args.size == 2 %}
      {% @type.constant("DECISION_HANDLED") << event_type %}

      def apply_event({{ block.args[0].id }} : State, {{ block.args[1].id }} : {{ event_type }}) : State
        body = {{ block.args[1].id }}.body.as({{ event_type }}::Body)
        {{ block.body }}
      end
    end

    # Handles an event whose body was erased: the block takes the state and the
    # event's header and returns the next state
    macro on_erased(event_type, &block)
      {% event_type.raise "on_erased #{event_type} expects a block taking |state, header|" unless block && block.args.size == 2 %}
      {% @type.constant("DECISION_ERASED") << event_type %}

      def apply_erased_event({{ block.args[0].id }} : State, {{ block.args[1].id }} : ::ES::Event::Header, _type : {{ event_type }}.class) : State
        {{ block.body }}
      end
    end

    # Names the tags every handled event must carry: `tags course_id: @course_id`
    macro tags(*args, **values)
      {% raise "tags takes named tags only, e.g. `tags course_id: @course_id`" unless args.empty? %}
      {% raise "tags needs at least one tag, e.g. `tags course_id: @course_id`" if values.empty? %}
      {% @type.constant("DECISION_TAGS") << values %}

      def tag_filter
        {{ values }}
      end
    end
  end

  # The outcome of `ES::EventStore#build_decision_model`: the state of each
  # projection, by the name it was given, and the condition guarding the append
  # the decision leads to.
  struct DecisionModel(S)
    # Named tuple of each projection's state
    getter state : S

    # The decision read the states were folded from
    getter decision : ES::Decision

    def initialize(@state : S, @decision : ES::Decision)
    end

    # The condition under which nothing any of the projections read has changed
    def condition : AppendCondition
      @decision.condition
    end

    # Names the states and counts the events only: states and event bodies may
    # hold personal data, decrypted
    def to_s(io : IO) : Nil
      io << "ES::DecisionModel(" << @state.keys.join(", ") << "; " << @decision.events.size << " events)"
    end

    # :ditto:
    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
