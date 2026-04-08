module ES
  class Projections
    @projection_handles = Hash(String, ES::Projection.class).new

    # Register a new projection
    def register(projection_class : ES::Projection.class)
      h = projection_class.handle
      raise ES::Exception::Conflict.new("handle '#{h}' already registered") if @projection_handles.has_key?(h)

      @projection_handles[h] = projection_class
    end

    # Return whether a projection handle is registered
    def registered?(handle : String) : Bool
      @projection_handles.has_key?(handle)
    end

    # Return the class for a given projection handle
    def projection_class(handle : String) : ES::Projection.class
      raise ES::Exception::NotFound.new("handle '#{handle}' not registered") unless @projection_handles.has_key?(handle)
      @projection_handles[handle]
    end

    # Return all registered projection handles
    def all : Array(String)
      @projection_handles.keys
    end
  end
end
