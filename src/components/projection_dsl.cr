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

        # One entry per declared index. Both the stored definition and the DDL
        # are built from this list so they cannot diverge. Every option is a
        # compile-time literal, so the generated SQL has no runtime input.
        idx_specs = idxs.map do |idx_def|
          idx_cols = idx_def.args[0]
          if !idx_cols.is_a?(ArrayLiteral) || idx_cols.empty?
            idx_def.raise "index expects a non-empty array of column symbols or expression strings, got: #{idx_cols}"
          end
          idx_cols.each do |idx_col|
            if !idx_col.is_a?(SymbolLiteral) && !idx_col.is_a?(StringLiteral)
              idx_def.raise "index entries must be column symbols (:email) or SQL expression strings (\"lower(email)\"), got: #{idx_col}"
            end
          end

          idx_opts = idx_def.named_args.is_a?(Nop) ? [] of Nil : idx_def.named_args
          idx_opts.each do |idx_opt|
            if !["unique", "name", "using", "opclass", "where", "include"].includes?(idx_opt.name.stringify)
              idx_def.raise "unknown index option '#{idx_opt.name}'; expected one of: unique, name, using, opclass, where, include"
            end
          end
          unique_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "unique" }
          name_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "name" }
          using_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "using" }
          opclass_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "opclass" }
          where_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "where" }
          include_opt = idx_opts.find { |idx_opt| idx_opt.name.stringify == "include" }

          is_unique = unique_opt ? unique_opt.value : false

          # A string entry is a raw SQL expression, a symbol a column name.
          is_expr = idx_cols.map(&.is_a?(StringLiteral))
          col_texts = idx_cols.map { |idx_col| idx_col.is_a?(StringLiteral) ? idx_col : idx_col.id.stringify }

          using = "btree"
          if using_opt
            if !using_opt.value.is_a?(SymbolLiteral) && !using_opt.value.is_a?(StringLiteral)
              idx_def.raise "index using: must be one of :btree, :gin, :gist, :hash, got: #{using_opt.value}"
            end
            using = using_opt.value.id.stringify
            if !["btree", "gin", "gist", "hash"].includes?(using)
              idx_def.raise "index using: must be one of :btree, :gin, :gist, :hash, got: #{using_opt.value}"
            end
          end

          # Normalised to one entry per column or expression, nil for none.
          opclasses = idx_cols.map { nil }
          if opclass_opt
            opclass_val = opclass_opt.value
            if opclass_val.is_a?(ArrayLiteral)
              if opclass_val.size != idx_cols.size
                idx_def.raise "index opclass: array has #{opclass_val.size} entries but the index has #{idx_cols.size} columns or expressions"
              end
              opclasses = opclass_val.map { |opc| opc.is_a?(NilLiteral) ? nil : opc }
            else
              opclasses = idx_cols.map { opclass_val }
            end
            opclasses = opclasses.map do |opc|
              if opc.nil?
                nil
              else
                if !opc.is_a?(SymbolLiteral) && !opc.is_a?(StringLiteral)
                  idx_def.raise "index opclass: entries must be symbols or strings, got: #{opc}"
                end
                if !(opc.id.stringify =~ /\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?\z/)
                  idx_def.raise "index opclass: '#{opc.id}' is not a valid operator class name"
                end
                opc.id.stringify
              end
            end
          end

          where_val = nil
          if where_opt
            if !where_opt.value.is_a?(StringLiteral) || where_opt.value.empty?
              idx_def.raise "index where: must be a non-empty string literal, got: #{where_opt.value}"
            end
            where_val = where_opt.value
          end

          include_cols = [] of Nil
          if include_opt
            if !include_opt.value.is_a?(ArrayLiteral) || include_opt.value.empty? || include_opt.value.any? { |inc| !inc.is_a?(SymbolLiteral) }
              idx_def.raise "index include: must be a non-empty array of column symbols, got: #{include_opt.value}"
            end
            if !["btree", "gist"].includes?(using)
              idx_def.raise "index include: is only supported with using: :btree or :gist, not :#{using.id}"
            end
            include_cols = include_opt.value.map(&.id.stringify)
          end

          # The generated name is derived from the column names only, so it
          # would be wrong (or collide with a plain index) for anything else.
          if !name_opt && (is_expr.includes?(true) || where_val || using != "btree")
            idx_def.raise "index #{idx_cols} needs an explicit name: when it uses an expression, where: or using:"
          end
          idx_name = name_opt ? name_opt.value : (table_name + "_" + col_texts.join("_") + "_idx")

          entry_sql = idx_cols.map_with_index do |idx_col, idx_ci|
            base = idx_col.is_a?(StringLiteral) ? "(" + idx_col + ")" : "\"" + idx_col.id.stringify + "\""
            opclasses[idx_ci] ? base + " " + opclasses[idx_ci] : base
          end
          sql = "CREATE" + (is_unique ? " UNIQUE" : "") + " INDEX IF NOT EXISTS " + idx_name.id.stringify +
                " ON \"" + schema_name + "\".\"" + table_name + "\"" +
                (using != "btree" ? " USING " + using : "") +
                " (" + entry_sql.join(", ") + ")" +
                (include_cols.empty? ? "" : " INCLUDE (" + include_cols.map { |inc| "\"" + inc + "\"" }.join(", ") + ")") +
                (where_val ? " WHERE " + where_val : "")

          {
            name:        idx_name,
            columns:     col_texts,
            unique:      is_unique,
            expressions: is_expr,
            using:       using,
            opclasses:   opclasses,
            where:       where_val,
            include:     include_cols,
            sql:         sql,
          }
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
                        {% for idx_col in idx_spec[:columns] %}
                          json.string {{ idx_col }}
                        {% end %}
                      end
                    end
                    json.field "unique", {{ idx_spec[:unique] }}
                    json.field "name", {{ idx_spec[:name] }}
                    # The fields below are written only when they differ from
                    # their default, so a plain column index serialises exactly
                    # as it did before they existed and keeps its fingerprint.
                    {% if idx_spec[:expressions].includes?(true) %}
                      json.field "expressions", {{ idx_spec[:expressions] }}
                    {% end %}
                    {% if idx_spec[:using] != "btree" %}
                      json.field "using", {{ idx_spec[:using] }}
                    {% end %}
                    {% if idx_spec[:opclasses].any? { |opc| opc } %}
                      json.field "opclass" do
                        json.array do
                          {% for opc in idx_spec[:opclasses] %}
                            {% if opc %}json.string {{ opc }}{% else %}json.null{% end %}
                          {% end %}
                        end
                      end
                    {% end %}
                    {% if idx_spec[:where] %}
                      json.field "where", {{ idx_spec[:where] }}
                    {% end %}
                    {% unless idx_spec[:include].empty? %}
                      json.field "include", {{ idx_spec[:include] }}
                    {% end %}
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
            { {{ idx_spec[:name] }}, {{ idx_spec[:sql] }} },
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
