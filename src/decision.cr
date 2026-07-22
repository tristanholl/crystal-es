module ES
  # Outcome of a pure decision function.
  # Accepted carries the events to append; Rejected carries a human-readable reason.
  # `events` on a Rejected decision returns an empty array (never raises).
  abstract class Decision(E)
    class Accepted(E) < Decision(E)
      getter events : Array(E)

      def initialize(@events : Array(E)); end

      def accepted? : Bool
        true
      end

      def rejected? : Bool
        false
      end

      def events : Array(E)
        @events
      end

      def reason : String
        raise "Decision::Accepted carries no reason"
      end

      def ==(other : Accepted(E)) : Bool
        @events == other.events
      end

      def ==(other : Decision(E)) : Bool
        false
      end
    end

    class Rejected(E) < Decision(E)
      getter reason : String

      def initialize(@reason : String); end

      def accepted? : Bool
        false
      end

      def rejected? : Bool
        true
      end

      def events : Array(E)
        [] of E
      end

      def ==(other : Rejected(E)) : Bool
        @reason == other.reason
      end

      def ==(other : Decision(E)) : Bool
        false
      end
    end

    def self.accept(events : Array(E)) : ES::Decision(E)
      Accepted(E).new(events)
    end

    def self.reject(reason : String) : ES::Decision(E)
      Rejected(E).new(reason)
    end

    abstract def accepted? : Bool
    abstract def rejected? : Bool
    abstract def events : Array(E)
    abstract def reason : String
  end
end
