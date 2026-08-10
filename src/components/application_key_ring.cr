module ES
  # Holds the application encryption keys — the KEKs that wrap every data
  # encryption key. These are the only secrets the application manages directly;
  # everything else is derived from them, which is the point of the design.
  #
  # Keys come from the environment:
  #
  # ```
  # ES_APPLICATION_KEYS        = "v1:<base64 32 bytes>,v2:<base64 32 bytes>"
  # ES_APPLICATION_KEY_CURRENT = "v2"
  # ```
  #
  # Several keys are held at once because that is what makes rotation possible: new
  # data keys are wrapped under `current_id`, older ones still unwrap under the id
  # recorded on their row, and `ES::Encryption#rewrap_all` migrates them across
  # without rewriting a single event.
  class ApplicationKeyRing
    ENV_KEYS    = "ES_APPLICATION_KEYS"
    ENV_CURRENT = "ES_APPLICATION_KEY_CURRENT"

    # The id new data keys are wrapped under
    getter current_id : String

    @keys : Hash(String, Bytes)

    def initialize(@keys : Hash(String, Bytes), @current_id : String)
      raise ES::Exception::InvalidState.new("Application key ring is empty") if @keys.empty?
      raise ES::Exception::InvalidState.new("Current application key '#{@current_id}' is not in the key ring") unless @keys.has_key?(@current_id)

      @keys.each do |id, material|
        raise ES::Exception::InvalidState.new("Application key '#{id}' must be #{ES::PayloadCipher::KEY_SIZE} bytes, got #{material.size}") if material.size != ES::PayloadCipher::KEY_SIZE
      end
    end

    # Builds a key ring from the environment.
    #
    # `ES_APPLICATION_KEY_CURRENT` may be omitted when the ring holds exactly one
    # key — there is nothing to choose between.
    def self.from_env(
      keys_variable : String = ENV_KEYS,
      current_variable : String = ENV_CURRENT,
    ) : ApplicationKeyRing
      raw = ENV[keys_variable]?
      raise ES::Exception::DependencyUnavailable.new("Environment variable '#{keys_variable}' is not set") if raw.nil? || raw.strip.empty?

      keys = Hash(String, Bytes).new
      raw.split(",") do |entry|
        e = entry.strip
        next if e.empty?

        id, separator, material = e.partition(":")
        raise ES::Exception::InvalidState.new("Malformed entry in '#{keys_variable}', expected '<id>:<base64 key>'") if separator.empty? || id.strip.empty? || material.strip.empty?

        keys[id.strip] = decode(id.strip, material.strip)
      end

      raise ES::Exception::InvalidState.new("Environment variable '#{keys_variable}' contains no keys") if keys.empty?

      current = ENV[current_variable]?
      if current.nil? || current.strip.empty?
        raise ES::Exception::InvalidState.new("Environment variable '#{current_variable}' must be set when '#{keys_variable}' holds more than one key") if keys.size > 1
        current = keys.first_key
      end

      new(keys, current.strip)
    end

    # The ids of every key in the ring
    def key_ids : Array(String)
      @keys.keys
    end

    # Wraps a data encryption key under the current application key, returning the
    # id it was wrapped under alongside the wrapped bytes
    def wrap(data_key : Bytes) : {String, Bytes}
      sealed = ES::PayloadCipher.seal(@keys[@current_id], data_key)
      {@current_id, ES::PayloadCipher.pack(sealed)}
    end

    # Unwraps a data encryption key using the application key it was wrapped under.
    #
    # A missing application key is a configuration fault, not a shredded key — the
    # data is still there, the environment is simply incomplete.
    def unwrap(application_encryption_key_id : String, wrapped : Bytes) : Bytes
      key = @keys[application_encryption_key_id]?
      raise ES::Exception::DependencyUnavailable.new("Application key '#{application_encryption_key_id}' is not in the key ring; event bodies wrapped under it cannot be read") if key.nil?

      ES::PayloadCipher.open(key, ES::PayloadCipher.unpack(wrapped))
    end

    private def self.decode(id : String, material : String) : Bytes
      Base64.decode(material)
    rescue
      raise ES::Exception::InvalidState.new("Application key '#{id}' is not valid base64")
    end
  end
end
