module ES
  module Exception
    class SchemaDrift < Error
      getter projection_class : String
      getter table_name : String
      getter stored_fingerprint : String
      getter compiled_fingerprint : String
      getter changes : Array(ES::ProjectionMeta::SchemaChange)

      def initialize(
        @projection_class : String,
        @table_name : String,
        @stored_fingerprint : String,
        @compiled_fingerprint : String,
        @changes : Array(ES::ProjectionMeta::SchemaChange),
      )
        change_summary = @changes.map { |c| "  [#{c.severity}] #{c.kind}: #{c.description}" }.join("\n")
        message = "Schema drift detected for '#{@projection_class}' (table: #{@table_name}).\n" \
                  "Stored fingerprint:   #{@stored_fingerprint}\n" \
                  "Compiled fingerprint: #{@compiled_fingerprint}\n" \
                  "Changes:\n#{change_summary}\n" \
                  "To rebuild: call force_replay! on this projection, or set ES_PROJECTION_RESET_ALL=true."
        super(message, print_backtrace: true, status_code: HTTP::Status::INTERNAL_SERVER_ERROR, type: self.class.to_s)
      end
    end
  end
end
