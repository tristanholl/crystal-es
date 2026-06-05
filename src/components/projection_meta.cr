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
        @changes.any? { |c| c.severity == "breaking" }
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
      return nil if result.nil?
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

    def self.diff(stored : String, compiled : String) : Array(SchemaChange)
      changes = [] of SchemaChange

      stored_def = JSON.parse(stored)
      compiled_def = JSON.parse(compiled)

      stored_cols = stored_def["columns"].as_a
      compiled_cols = compiled_def["columns"].as_a

      max_size = [stored_cols.size, compiled_cols.size].max
      max_size.times do |i|
        sc = stored_cols[i]?
        cc = compiled_cols[i]?

        if sc && cc.nil?
          changes << SchemaChange.new("breaking", "column_removed",
            "Column '#{sc["name"]}' at position #{i} was removed")
        elsif cc && sc.nil?
          changes << SchemaChange.new("breaking", "column_added",
            "Column '#{cc["name"]}' was added at position #{i}")
        elsif sc && cc
          if sc["name"] != cc["name"]
            changes << SchemaChange.new("breaking", "column_order_changed",
              "Column at position #{i} changed from '#{sc["name"]}' to '#{cc["name"]}'")
          else
            col_name = sc["name"].as_s
            if sc["sql_type"] != cc["sql_type"]
              changes << SchemaChange.new("breaking", "column_type_changed",
                "Column '#{col_name}' type changed from #{sc["sql_type"]} to #{cc["sql_type"]}")
            end
            if sc["null"] != cc["null"]
              changes << SchemaChange.new("breaking", "column_nullability_changed",
                "Column '#{col_name}' nullability changed from null=#{sc["null"]} to null=#{cc["null"]}")
            end
            if sc["default"] != cc["default"]
              changes << SchemaChange.new("breaking", "column_default_changed",
                "Column '#{col_name}' default changed from #{sc["default"]} to #{cc["default"]}")
            end
            sc_ct = sc["crystal_type"]?
            cc_ct = cc["crystal_type"]?
            if sc_ct && cc_ct && sc_ct != cc_ct
              changes << SchemaChange.new("breaking", "column_crystal_type_changed",
                "Column '#{col_name}' Crystal type changed from #{sc_ct} to #{cc_ct}")
            end
          end
        end
      end

      stored_idxs = stored_def["indexes"].as_a
      compiled_idxs = compiled_def["indexes"].as_a

      stored_names = stored_idxs.map { |idx| idx["name"].as_s }
      compiled_names = compiled_idxs.map { |idx| idx["name"].as_s }

      (stored_names - compiled_names).each do |name|
        changes << SchemaChange.new("non_breaking", "index_removed", "Index '#{name}' was removed")
      end

      (compiled_names - stored_names).each do |name|
        changes << SchemaChange.new("non_breaking", "index_added", "Index '#{name}' was added")
      end

      (stored_names & compiled_names).each do |name|
        s_idx = stored_idxs.find { |idx| idx["name"].as_s == name }.not_nil!
        c_idx = compiled_idxs.find { |idx| idx["name"].as_s == name }.not_nil!
        if s_idx["columns"] != c_idx["columns"] || s_idx["unique"] != c_idx["unique"]
          changes << SchemaChange.new("non_breaking", "index_changed",
            "Index '#{name}' definition changed")
        end
      end

      changes
    end
  end
end
