module ES
  module ProjectionDSL
    macro column(name, type, **options)
    end

    macro index(columns, **options)
    end

    macro apply(event_type, &block)
      def apply(event : {{ event_type }})
        header = event.header
        aggregate_id = event.header.aggregate_id
        aggregate_version = event.header.aggregate_version
        created_at = event.header.created_at
        body = event.body.as({{ event_type }}::Body)
        {{ block.body }}
      end
    end

    macro define_projection(table, init = false, batch_size = 1000_i64)
      {% raise "define_projection requires at least one column declaration; add a block with `column` calls" %}
    end

    macro define_projection(table, init = false, batch_size = 1000_i64, &block)
      @@table = {{ table }}
      @@init = {{ init }}
      @@projection_batch_size = {{ batch_size }}.to_i64

      {%
        parts = table.split(".")
        schema_name = parts.size >= 2 ? parts[0] : "public"
        table_name = parts.size >= 2 ? parts[1] : parts[0]

        entries = if block.nil? || block.body.nil?
                    [] of Nil
                  elsif block.body.is_a?(Expressions)
                    block.body.expressions
                  else
                    [block.body]
                  end

        cols = entries.select { |e| e.name.stringify == "column" }
        idxs = entries.select { |e| e.name.stringify == "index" }

        # One entry per declared index: [name, columns, unique]. Both the stored
        # definition and the DDL are built from this list so they cannot diverge.
        idx_specs = idxs.map do |idx_def|
          idx_cols = idx_def.args[0]
          idx_opts = idx_def.named_args.is_a?(Nop) ? [] of Nil : idx_def.named_args
          unique_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "unique" }
          name_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "name" }
          is_unique = unique_opt ? unique_opt.value : false
          idx_name = name_opt ? name_opt.value : (table_name + "_" + idx_cols.map(&.id.stringify).join("_") + "_idx")
          [idx_name, idx_cols, is_unique]
        end
      %}

      def self.compiled_definition : String
        JSON.build do |json|
          json.object do
            json.field "table", {{ table }}
            json.field "columns" do
              json.array do
                {% for col_def, col_i in cols %}
                  {% col_name = col_def.args[0].id %}
                  {% col_type_str = col_def.args[1].stringify %}
                  {% is_primary = false %}
                  {% is_serial = false %}
                  {% is_bigserial = false %}
                  {% is_null = false %}
                  {% has_default = false %}
                  {% default_val = nil %}
                  {% for col_opt in (col_def.named_args.is_a?(Nop) ? [] of Nil : col_def.named_args) %}
                    {% if col_opt.name.stringify == "primary_key" %}{% is_primary = col_opt.value %}{% end %}
                    {% if col_opt.name.stringify == "serial" %}{% is_serial = col_opt.value %}{% end %}
                    {% if col_opt.name.stringify == "bigserial" %}{% is_bigserial = col_opt.value %}{% end %}
                    {% if col_opt.name.stringify == "null" %}{% is_null = col_opt.value %}{% end %}
                    {% if col_opt.name.stringify == "default" %}{% has_default = true %}{% default_val = col_opt.value %}{% end %}
                  {% end %}
                  {% if is_serial %}
                    {% sql_type = "SERIAL" %}
                  {% elsif is_bigserial %}
                    {% sql_type = "BIGSERIAL" %}
                  {% elsif col_type_str == "String" %}
                    {% sql_type = "TEXT" %}
                  {% elsif col_type_str == "Int32" %}
                    {% sql_type = "INTEGER" %}
                  {% elsif col_type_str == "Int64" %}
                    {% sql_type = "BIGINT" %}
                  {% elsif col_type_str == "Float64" %}
                    {% sql_type = "DOUBLE PRECISION" %}
                  {% elsif col_type_str == "Bool" %}
                    {% sql_type = "BOOLEAN" %}
                  {% elsif col_type_str == "UUID" %}
                    {% sql_type = "UUID" %}
                  {% elsif col_type_str == "Time" %}
                    {% sql_type = "TIMESTAMPTZ" %}
                  {% elsif col_type_str == "JSON::Any" %}
                    {% sql_type = "JSONB" %}
                  {% else %}
                    {% sql_type = "TEXT" %}
                  {% end %}
                  json.object do
                    json.field "name", "{{ col_name }}"
                    json.field "sql_type", {{ sql_type }}
                    json.field "crystal_type", {{ col_type_str }}
                    json.field "primary_key", {{ is_primary }}
                    json.field "null", {{ is_null }}
                    {% if has_default %}
                      json.field "default", {{ default_val }}
                    {% else %}
                      json.field "default" { json.null }
                    {% end %}
                    json.field "position", {{ col_i }}
                  end
                {% end %}
              end
            end
            json.field "indexes" do
              json.array do
                {% for idx_spec in idx_specs %}
                  json.object do
                    json.field "columns" do
                      json.array do
                        {% for idx_col in idx_spec[1] %}
                          json.string "{{ idx_col.id }}"
                        {% end %}
                      end
                    end
                    json.field "unique", {{ idx_spec[2] }}
                    json.field "name", {{ idx_spec[0] }}
                  end
                {% end %}
              end
            end
          end
        end
      end

      # `{name, sql}` for every declared index. The SQL is idempotent
      # (`IF NOT EXISTS`), so it is safe to run on every boot.
      def self.index_ddl : Array({String, String})
        [
          {% for idx_spec in idx_specs %}
            { {{ idx_spec[0] }}, %(CREATE{% if idx_spec[2] %} UNIQUE{% end %} INDEX IF NOT EXISTS {{ idx_spec[0].id }} ON "{{ schema_name.id }}"."{{ table_name.id }}" ({% for idx_col, idx_ci in idx_spec[1] %}"{{ idx_col.id }}"{% if idx_ci < idx_spec[1].size - 1 %}, {% end %}{% end %})) },
          {% end %}
        ] of {String, String}
      end

      def self.compiled_fingerprint : String
        ::Digest::SHA256.hexdigest(compiled_definition)
      end

      def self.drift_status(db : DB::Database) : ES::ProjectionMeta::DriftStatus
        meta_helper = ES::ProjectionMeta.new(db, {{ schema_name }})
        meta_helper.setup
        stored = meta_helper.fetch(self.name)

        if stored.nil?
          ES::ProjectionMeta::DriftStatus.new(
            verified: false,
            stored_definition: nil,
            compiled_definition: compiled_definition,
            changes: [] of ES::ProjectionMeta::SchemaChange,
          )
        elsif stored.fingerprint == compiled_fingerprint
          ES::ProjectionMeta::DriftStatus.new(
            verified: true,
            stored_definition: stored.definition,
            compiled_definition: compiled_definition,
            changes: [] of ES::ProjectionMeta::SchemaChange,
          )
        else
          changes = ES::ProjectionMeta.diff(stored.definition, compiled_definition)
          ES::ProjectionMeta::DriftStatus.new(
            verified: false,
            stored_definition: stored.definition,
            compiled_definition: compiled_definition,
            changes: changes,
          )
        end
      end

      private def create_projection_table
        @projection_database.exec %(
          CREATE TABLE "{{ schema_name.id }}"."{{ table_name.id }}" (
            {% for col_def, col_i in cols %}
              {% col_name = col_def.args[0].id %}
              {% col_type_str = col_def.args[1].stringify %}
              {% is_primary = false %}
              {% is_serial = false %}
              {% is_bigserial = false %}
              {% is_null = false %}
              {% has_default = false %}
              {% default_val = nil %}
              {% for col_opt in (col_def.named_args.is_a?(Nop) ? [] of Nil : col_def.named_args) %}
                {% if col_opt.name.stringify == "primary_key" %}{% is_primary = col_opt.value %}{% end %}
                {% if col_opt.name.stringify == "serial" %}{% is_serial = col_opt.value %}{% end %}
                {% if col_opt.name.stringify == "bigserial" %}{% is_bigserial = col_opt.value %}{% end %}
                {% if col_opt.name.stringify == "null" %}{% is_null = col_opt.value %}{% end %}
                {% if col_opt.name.stringify == "default" %}{% has_default = true %}{% default_val = col_opt.value %}{% end %}
              {% end %}
              {% if is_serial %}
                {% sql_type = "SERIAL" %}
              {% elsif is_bigserial %}
                {% sql_type = "BIGSERIAL" %}
              {% elsif col_type_str == "String" %}
                {% sql_type = "TEXT" %}
              {% elsif col_type_str == "Int32" %}
                {% sql_type = "INTEGER" %}
              {% elsif col_type_str == "Int64" %}
                {% sql_type = "BIGINT" %}
              {% elsif col_type_str == "Float64" %}
                {% sql_type = "DOUBLE PRECISION" %}
              {% elsif col_type_str == "Bool" %}
                {% sql_type = "BOOLEAN" %}
              {% elsif col_type_str == "UUID" %}
                {% sql_type = "UUID" %}
              {% elsif col_type_str == "Time" %}
                {% sql_type = "TIMESTAMPTZ" %}
              {% elsif col_type_str == "JSON::Any" %}
                {% sql_type = "JSONB" %}
              {% else %}
                {% sql_type = "TEXT" %}
              {% end %}
              "{{ col_name }}" {{ sql_type.id }} {% if is_primary %}PRIMARY KEY{% elsif is_null %}NULL{% else %}NOT NULL{% end %}{% if has_default %} DEFAULT {% if default_val.is_a?(StringLiteral) %}'{{ default_val.id }}'{% else %}{{ default_val }}{% end %}{% end %}{% if col_i < cols.size - 1 %},{% end %}
            {% end %}
          )
        )
      end

      # Drops the indexes in `drop` and then creates every declared index that
      # does not exist yet, in one transaction. Running the creates on every
      # boot also repairs indexes that are missing although the stored metadata
      # lists them (dropped by hand, or recorded by a version that never built
      # them). If a create fails, e.g. a unique index over duplicate rows, the
      # drops are rolled back and the error propagates, so the caller never
      # records the new definition.
      private def sync_projection_indexes(drop : Array(String) = [] of String) : Nil
        ddl = self.class.index_ddl
        return if drop.empty? && ddl.empty?

        @projection_database.transaction do |tx|
          conn = tx.connection
          drop.each do |name|
            # Index names are unique per schema, not per table.
            conn.exec %(DROP INDEX IF EXISTS "{{ schema_name.id }}".#{name})
          end
          ddl.each do |(name, sql)|
            begin
              conn.exec sql
            rescue ex
              Log.error { "Failed to create index '#{name}' for '#{self.class.name}': #{ex.message}" }
              raise ex
            end
          end
        end
      end

      def setup_table
        meta_helper = ES::ProjectionMeta.new(@projection_database, {{ schema_name }})
        meta_helper.setup

        compiled_fp  = self.class.compiled_fingerprint
        compiled_def = self.class.compiled_definition

        if stored = meta_helper.fetch(self.class.name)
          if stored.fingerprint != compiled_fp
            changes = ES::ProjectionMeta.diff(stored.definition, compiled_def)
            if changes.any? { |c| c.severity == "breaking" }
              raise ES::Exception::SchemaDrift.new(
                projection_class: self.class.name,
                table_name: self.class.table,
                stored_fingerprint: stored.fingerprint,
                compiled_fingerprint: compiled_fp,
                changes: changes,
              )
            else
              reason = changes.empty? \
                ? "definition metadata was updated (no structural changes detected)" \
                : changes.map(&.description).join(", ")
              Log.warn { "Non-breaking schema drift on '#{self.class.name}': #{reason}" }

              # Removed indexes and indexes whose definition changed are
              # dropped; the sync then (re)creates every declared index.
              drop = changes.compact_map do |change|
                change.index_name if change.kind.in?("index_removed", "index_changed")
              end
              sync_projection_indexes(drop)
              meta_helper.upsert(self.class.name, self.class.table, compiled_fp, compiled_def)
            end
          else
            sync_projection_indexes
          end
          init
          return
        end

        skip = @projection_database.query_one(
          %(SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname = '{{ schema_name.id }}' AND tablename = '{{ table_name.id }}')),
          as: Bool
        )
        create_projection_table unless skip
        sync_projection_indexes

        meta_helper.upsert(self.class.name, self.class.table, compiled_fp, compiled_def)
        init
      end

      def setup
        setup_table
      end
    end
  end
end
