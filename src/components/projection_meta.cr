module ES
  class ProjectionMeta
    struct SchemaChange
      getter severity : String # "breaking" | "non_breaking"
      getter kind : String     # "column_removed" | "column_type_changed" | ...
      getter description : String

      def initialize(@severity : String, @kind : String, @description : String)
      end
    end

    struct DriftStatus
      getter verified : Bool
      getter stored_definition : String?
      getter compiled_definition : String
      getter changes : Array(SchemaChange)

      def initialize(
        @verified : Bool,
        @stored_definition : String?,
        @compiled_definition : String,
        @changes : Array(SchemaChange),
      )
      end

      def drifted? : Bool
        !@verified
      end

      def breaking? : Bool
        @changes.any? { |change| change.severity == "breaking" }
      end
    end

    struct MetaRow
      getter projection_class : String
      getter table_name : String
      getter fingerprint : String
      getter definition : String
      getter recorded_at : Time

      def initialize(
        @projection_class : String,
        @table_name : String,
        @fingerprint : String,
        @definition : String,
        @recorded_at : Time,
      )
      end
    end

    META_TABLE = "_crystal_es_projection_metadata"

    def initialize(@db : DB::Database, @schema : String)
    end

    def setup : Nil
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS "#{@schema}"."#{META_TABLE}" (
          "projection_class"  TEXT        NOT NULL,
          "table_name"        TEXT        NOT NULL,
          "fingerprint"       TEXT        NOT NULL,
          "definition"        JSONB       NOT NULL,
          "recorded_at"       TIMESTAMPTZ NOT NULL DEFAULT now(),
          CONSTRAINT projection_meta_pk PRIMARY KEY ("projection_class")
        )
        SQL
      @db.exec <<-SQL
        CREATE UNIQUE INDEX IF NOT EXISTS crystal_es_projection_metadata_table_name_uidx
          ON "#{@schema}"."#{META_TABLE}" ("table_name")
        SQL
    end

    def fetch(projection_class : String) : MetaRow?
      result = @db.query_one?(
        %(SELECT projection_class, table_name, fingerprint, definition::text, recorded_at FROM "#{@schema}"."#{META_TABLE}" WHERE projection_class = $1),
        projection_class,
        as: {String, String, String, String, Time}
      )
      return if result.nil?
      pc, tn, fp, defn, recorded = result
      MetaRow.new(
        projection_class: pc,
        table_name: tn,
        fingerprint: fp,
        definition: defn,
        recorded_at: recorded
      )
    end

    def upsert(projection_class : String, table_name : String, fingerprint : String, definition : String) : Nil
      @db.exec(
        %(INSERT INTO "#{@schema}"."#{META_TABLE}" (projection_class, table_name, fingerprint, definition, recorded_at) VALUES ($1, $2, $3, $4::jsonb, now()) ON CONFLICT (projection_class) DO UPDATE SET table_name = EXCLUDED.table_name, fingerprint = EXCLUDED.fingerprint, definition = EXCLUDED.definition, recorded_at = EXCLUDED.recorded_at),
        projection_class, table_name, fingerprint, definition
      )
    end

    # Compares a stored projection definition against the compiled one and
    # reports every schema change between them.
    def self.diff(stored : String, compiled : String) : Array(SchemaChange)
      stored_def = JSON.parse(stored)
      compiled_def = JSON.parse(compiled)

      changes = diff_columns(stored_def["columns"].as_a, compiled_def["columns"].as_a)
      changes.concat(diff_indexes(stored_def["indexes"].as_a, compiled_def["indexes"].as_a))
      changes
    end

    # Column order is part of the projection schema, so the two lists are walked
    # position by position and a moved column counts as a breaking change.
    private def self.diff_columns(stored_cols : Array(JSON::Any), compiled_cols : Array(JSON::Any)) : Array(SchemaChange)
      changes = [] of SchemaChange

      max_size = [stored_cols.size, compiled_cols.size].max
      max_size.times do |i|
        stored_col = stored_cols[i]?
        compiled_col = compiled_cols[i]?

        if stored_col && compiled_col.nil?
          changes << SchemaChange.new("breaking", "column_removed",
            "Column '#{stored_col["name"]}' at position #{i} was removed")
        elsif compiled_col && stored_col.nil?
          changes << SchemaChange.new("breaking", "column_added",
            "Column '#{compiled_col["name"]}' was added at position #{i}")
        elsif stored_col && compiled_col
          if stored_col["name"] != compiled_col["name"]
            changes << SchemaChange.new("breaking", "column_order_changed",
              "Column at position #{i} changed from '#{stored_col["name"]}' to '#{compiled_col["name"]}'")
          else
            changes.concat(diff_column_attributes(stored_col, compiled_col))
          end
        end
      end

      changes
    end

    # Compares the attributes of a single column that kept both its name and its
    # position. Every attribute change here is breaking: the table would have to
    # be altered for the projection to keep writing to it.
    private def self.diff_column_attributes(stored_col : JSON::Any, compiled_col : JSON::Any) : Array(SchemaChange)
      changes = [] of SchemaChange
      col_name = stored_col["name"].as_s

      if stored_col["sql_type"] != compiled_col["sql_type"]
        changes << SchemaChange.new("breaking", "column_type_changed",
          "Column '#{col_name}' type changed from #{stored_col["sql_type"]} to #{compiled_col["sql_type"]}")
      end
      if stored_col["null"] != compiled_col["null"]
        changes << SchemaChange.new("breaking", "column_nullability_changed",
          "Column '#{col_name}' nullability changed from null=#{stored_col["null"]} to null=#{compiled_col["null"]}")
      end
      if stored_col["default"] != compiled_col["default"]
        changes << SchemaChange.new("breaking", "column_default_changed",
          "Column '#{col_name}' default changed from #{stored_col["default"]} to #{compiled_col["default"]}")
      end
      if stored_col["primary_key"] != compiled_col["primary_key"]
        changes << SchemaChange.new("breaking", "column_primary_key_changed",
          "Column '#{col_name}' primary_key changed from #{stored_col["primary_key"]} to #{compiled_col["primary_key"]}")
      end

      stored_crystal_type = stored_col["crystal_type"]?
      compiled_crystal_type = compiled_col["crystal_type"]?
      if stored_crystal_type && compiled_crystal_type && stored_crystal_type != compiled_crystal_type
        changes << SchemaChange.new("breaking", "column_crystal_type_changed",
          "Column '#{col_name}' Crystal type changed from #{stored_crystal_type} to #{compiled_crystal_type}")
      end

      changes
    end

    # Indexes are matched by name rather than by position, and none of their
    # changes are breaking: an index can be dropped and recreated in place.
    private def self.diff_indexes(stored_idxs : Array(JSON::Any), compiled_idxs : Array(JSON::Any)) : Array(SchemaChange)
      changes = [] of SchemaChange

      stored_names = stored_idxs.map(&.["name"].as_s)
      compiled_names = compiled_idxs.map(&.["name"].as_s)

      (stored_names - compiled_names).each do |name|
        changes << SchemaChange.new("non_breaking", "index_removed", "Index '#{name}' was removed")
      end

      (compiled_names - stored_names).each do |name|
        changes << SchemaChange.new("non_breaking", "index_added", "Index '#{name}' was added")
      end

      (stored_names & compiled_names).each do |name|
        stored_idx = stored_idxs.find! { |idx| idx["name"].as_s == name }
        compiled_idx = compiled_idxs.find! { |idx| idx["name"].as_s == name }
        if stored_idx["columns"] != compiled_idx["columns"] || stored_idx["unique"] != compiled_idx["unique"]
          changes << SchemaChange.new("non_breaking", "index_changed",
            "Index '#{name}' definition changed")
        end
      end

      changes
    end
  end
end
