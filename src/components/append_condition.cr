module ES
  # Consistency condition for an atomic append (Dynamic Consistency Boundary).
  #
  # Maps sequence keys to the last version seen when the decision model was built.
  # A sequence key is either an aggregate_id (as string) or a tag. An expected
  # version of 0 asserts that the sequence is still empty. Condition keys may
  # reference sequences the append does not write to (read-only boundary members).
  struct AppendCondition
    getter expected : Hash(String, Int32)

    def initialize(@expected : Hash(String, Int32) = {} of String => Int32)
    end

    # Returns an unconditional append condition
    def self.none
      new
    end

    # Returns true if no expectations are set
    def empty? : Bool
      @expected.empty?
    end
  end
end
