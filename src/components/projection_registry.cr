module ES
  class ProjectionRegistry
    @projections = Array(ES::Projection.class).new

    # Register a new projection
    def register(projection_class : ES::Projection.class)
      raise ES::Exception::Conflict.new("'#{projection_class.name}' already registered") if @projections.includes?(projection_class)

      @projections << projection_class
    end

    # Return whether a projection class is registered
    def registered?(projection_class : ES::Projection.class) : Bool
      @projections.includes?(projection_class)
    end

    # Return all registered projection classes
    def all : Array(ES::Projection.class)
      @projections.dup
    end
  end
end
