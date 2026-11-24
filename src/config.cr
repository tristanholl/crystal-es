module ES
  module Config
    extend self

    class_property version : String = "unknown"

    def event_bus=(param : ES::EventBus(ES::Reactor.class | ES::Projection.class))
      @@eventbus = param
    end

    def event_bus : ES::EventBus
      eb = @@eventbus
      raise "No eventbus registered" if eb.nil?
      eb
    end

    def encryption=(param : ES::EncryptionKeyManager)
      @@encryption = param
    end

    def encryption : ES::EncryptionKeyManager
      e = @@encryption
      raise "No encryption registered" if e.nil?
      e
    end

    # Encryption is optional, so the event stores ask for it this way — an
    # unconfigured library behaves exactly as it did before encryption existed.
    def encryption? : ES::EncryptionKeyManager?
      @@encryption
    end

    def tag_hasher=(param : ES::TagHasher)
      @@tag_hasher = param
    end

    def tag_hasher : ES::TagHasher
      t = @@tag_hasher
      raise "No tag hasher registered" if t.nil?
      t
    end

    # Hashing tags is optional, like encryption: unhashed tags need nothing
    # configured, so the event stores ask for the hasher this way.
    def tag_hasher? : ES::TagHasher?
      @@tag_hasher
    end

    def event_handlers=(param : ES::EventHandlers)
      @@event_handlers = param
    end

    def event_handlers : ES::EventHandlers
      h = @@event_handlers
      raise "No default event handlers registered" if h.nil?
      h
    end

    def event_store=(param : ES::EventStore)
      @@event_store = param
    end

    def event_store : ES::EventStore
      e = @@event_store
      raise "No default eventstore registered" if e.nil?
      e
    end

    def projection_database=(param : DB::Database)
      @@projection_database = param
    end

    def projection_database : DB::Database
      p = @@projection_database
      raise "No default projection database registered" if p.nil?
      p
    end

    # The projection database if one is configured, for components that can
    # work without one
    def projection_database? : DB::Database?
      @@projection_database
    end

    def projection_registry=(param : ES::ProjectionRegistry)
      @@projection_registry = param
    end

    def projection_registry : ES::ProjectionRegistry
      h = @@projection_registry
      raise "No default projection registry registered" if h.nil?
      h
    end
  end
end
