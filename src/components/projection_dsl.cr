module ES
  module ProjectionDSL
    macro column(name, type, **options)
    end

    macro index(columns, **options)
    end

    macro apply(event_type, &block)
      def apply(event : {{event_type}})
        header = event.header
        aggregate_id = event.header.aggregate_id
        aggregate_version = event.header.aggregate_version
        created_at = event.header.created_at
        body = event.body.as({{event_type}}::Body)
        {{block.body}}
      end
    end

    macro define_projection(table, init = false, batch_size = 1000_i64, reset_on_drift = false)
      {% raise "define_projection requires at least one column declaration; add a block with `column` calls" %}
    end

    macro define_projection(table, init = false, batch_size = 1000_i64, reset_on_drift = false, &block)
      @@table = {{table}}
      @@init = {{init}}
      @@projection_batch_size = {{batch_size}}.to_i64

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
      %}

      def self.compiled_definition : String
        JSON.build do |json|
          json.object do
            json.field "table", {{table}}
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
                  {% for col_opt in col_def.named_args %}
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
                    json.field "name", "{{col_name}}"
                    json.field "sql_type", {{sql_type}}
                    json.field "primary_key", {{is_primary}}
                    json.field "null", {{is_null}}
                    {% if has_default %}
                      json.field "default", {{default_val}}
                    {% else %}
                      json.field "default" { json.null }
                    {% end %}
                    json.field "position", {{col_i}}
                  end
                {% end %}
              end
            end
            json.field "indexes" do
              json.array do
                {% for idx_def in idxs %}
                  {% idx_cols = idx_def.args[0] %}
                  {% is_unique = false %}
                  {% idx_name = nil %}
                  {% for idx_opt in idx_def.named_args %}
                    {% if idx_opt.name.stringify == "unique" %}{% is_unique = idx_opt.value %}{% end %}
                    {% if idx_opt.name.stringify == "name" %}{% idx_name = idx_opt.value %}{% end %}
                  {% end %}
                  json.object do
                    json.field "columns" do
                      json.array do
                        {% for idx_col in idx_cols %}
                          json.string "{{idx_col.id}}"
                        {% end %}
                      end
                    end
                    json.field "unique", {{is_unique}}
                    {% if idx_name %}
                      json.field "name", {{idx_name}}
                    {% else %}
                      json.field "name", "{{table_name.id}}_{% for idx_col, idx_ci in idx_cols %}{{idx_col.id}}{% if idx_ci < idx_cols.size - 1 %}_{% end %}{% end %}_idx"
                    {% end %}
                  end
                {% end %}
              end
            end
          end
        end
      end

      def self.compiled_fingerprint : String
        ::Digest::SHA256.hexdigest(compiled_definition)
      end

      def self.drift_status(db : DB::Database) : ES::ProjectionMeta::DriftStatus
        meta_helper = ES::ProjectionMeta.new(db, {{schema_name}})
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
          CREATE TABLE "{{schema_name.id}}"."{{table_name.id}}" (
            {% for col_def, col_i in cols %}
              {% col_name = col_def.args[0].id %}
              {% col_type_str = col_def.args[1].stringify %}
              {% is_primary = false %}
              {% is_serial = false %}
              {% is_bigserial = false %}
              {% is_null = false %}
              {% has_default = false %}
              {% default_val = nil %}
              {% for col_opt in col_def.named_args %}
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
              "{{col_name}}" {{sql_type.id}} {% if is_primary %}PRIMARY KEY{% elsif is_null %}NULL{% else %}NOT NULL{% end %}{% if has_default %} DEFAULT {% if default_val.is_a?(StringLiteral) %}'{{default_val.id}}'{% else %}{{default_val}}{% end %}{% end %}{% if col_i < cols.size - 1 %},{% end %}
            {% end %}
          )
        )

        {% for idx_def in idxs %}
          {% idx_cols = idx_def.args[0] %}
          {% is_unique = false %}
          {% idx_name = nil %}
          {% for idx_opt in idx_def.named_args %}
            {% if idx_opt.name.stringify == "unique" %}{% is_unique = idx_opt.value %}{% end %}
            {% if idx_opt.name.stringify == "name" %}{% idx_name = idx_opt.value %}{% end %}
          {% end %}
          @projection_database.exec %(CREATE{% if is_unique %} UNIQUE{% end %} INDEX {% if idx_name %}{{idx_name.id}}{% else %}{{table_name.id}}_{% for idx_col, idx_ci in idx_cols %}{{idx_col.id}}{% if idx_ci < idx_cols.size - 1 %}_{% end %}{% end %}_idx{% end %} ON "{{schema_name.id}}"."{{table_name.id}}"({% for idx_col, idx_ci in idx_cols %}{{idx_col.id}}{% if idx_ci < idx_cols.size - 1 %}, {% end %}{% end %}))
        {% end %}
      end

      def force_replay! : Nil
        meta_helper = ES::ProjectionMeta.new(@projection_database, {{schema_name}})
        meta_helper.setup
        @projection_database.exec %(DROP TABLE IF EXISTS "{{schema_name.id}}"."{{table_name.id}}" CASCADE)
        create_projection_table
        meta_helper.upsert(self.class.name, self.class.table, self.class.compiled_fingerprint, self.class.compiled_definition)
        replay(truncate: true)
        meta_helper.mark_replayed(self.class.name)
      end

      def setup_table
        meta_helper = ES::ProjectionMeta.new(@projection_database, {{schema_name}})
        meta_helper.setup

        compiled_fp  = self.class.compiled_fingerprint
        compiled_def = self.class.compiled_definition

        if stored = meta_helper.fetch(self.class.name)
          if stored.fingerprint != compiled_fp
            changes = ES::ProjectionMeta.diff(stored.definition, compiled_def)
            if changes.any? { |c| c.severity == "breaking" }
              if {{reset_on_drift}} || ENV["ES_PROJECTION_RESET_ALL"]? == "true"
                force_replay!
                return
              else
                raise ES::Exception::SchemaDrift.new(
                  projection_class: self.class.name,
                  table_name: self.class.table,
                  stored_fingerprint: stored.fingerprint,
                  compiled_fingerprint: compiled_fp,
                  changes: changes,
                )
              end
            else
              Log.warn { "Non-breaking schema drift on '#{self.class.name}': #{changes.map(&.description).join(", ")}" }
              meta_helper.upsert(self.class.name, self.class.table, compiled_fp, compiled_def)
            end
          end
          init
          return
        end

        skip = @projection_database.query_one(
          %(SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname = '{{schema_name.id}}' AND tablename = '{{table_name.id}}')),
          as: Bool
        )
        create_projection_table unless skip

        meta_helper.upsert(self.class.name, self.class.table, compiled_fp, compiled_def)
        init
      end

      def setup
        setup_table
      end
    end
  end
end
