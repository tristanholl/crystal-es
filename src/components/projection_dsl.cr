module ES
  module ProjectionDSL
    macro column(name, type, **options)
    end

    macro index(columns, **options)
    end

    macro define_projection(handle, table)
      define_projection({{handle}}, {{table}}) do
      end
    end

    macro define_projection(handle, table, &block)
      @@handle = {{handle}}
      @@table  = {{table}}

      {%
        parts = table.split(".")
        schema_name = parts.size >= 2 ? parts[0] : "public"
        table_name  = parts.size >= 2 ? parts[1] : parts[0]

        entries = if block.nil? || block.body.nil?
                    [] of Nil
                  elsif block.body.is_a?(Expressions)
                    block.body.expressions
                  else
                    [block.body]
                  end

        cols = [] of Nil
        idxs = [] of Nil

        for entry in entries
          if entry.is_a?(Call)
            if entry.name.stringify == "column"
              cols << entry
            elsif entry.name.stringify == "index"
              idxs << entry
            end
          end
        end
      %}

      def setup_table
        skip = @projection_database.query_one(
          %(SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname = '{{schema_name.id}}' AND tablename = '{{table_name.id}}')),
          as: Bool
        )
        return if skip

        @projection_database.exec %(
          CREATE TABLE "{{schema_name.id}}"."{{table_name.id}}" (
            {% for col, i in cols %}
              {%
                col_name = col.args[0].id
                col_type_str = col.args[1].stringify
                is_primary = false
                is_serial = false
                is_bigserial = false
                is_null = false
                has_default = false
                default_val = nil

                for opt in col.named_args
                  if opt.name.stringify == "primary_key"
                    is_primary = opt.value
                  end
                  if opt.name.stringify == "serial"
                    is_serial = opt.value
                  end
                  if opt.name.stringify == "bigserial"
                    is_bigserial = opt.value
                  end
                  if opt.name.stringify == "null"
                    is_null = opt.value
                  end
                  if opt.name.stringify == "default"
                    has_default = true
                    default_val = opt.value
                  end
                end

                sql_type = if is_serial
                              "SERIAL"
                            elsif is_bigserial
                              "BIGSERIAL"
                            elsif col_type_str == "String"
                              "TEXT"
                            elsif col_type_str == "Int32"
                              "INTEGER"
                            elsif col_type_str == "Int64"
                              "BIGINT"
                            elsif col_type_str == "Float64"
                              "DOUBLE PRECISION"
                            elsif col_type_str == "Bool"
                              "BOOLEAN"
                            elsif col_type_str == "UUID"
                              "UUID"
                            elsif col_type_str == "Time"
                              "TIMESTAMPTZ"
                            elsif col_type_str == "JSON::Any"
                              "JSONB"
                            else
                              "TEXT"
                            end
              %}
              "{{col_name}}" {{sql_type.id}} {% if is_primary %}PRIMARY KEY{% elsif is_null %}NULL{% else %}NOT NULL{% end %}{% if has_default %} DEFAULT {% if default_val.is_a?(StringLiteral) %}'{{default_val.id}}'{% else %}{{default_val}}{% end %}{% end %}{% if i < cols.size - 1 %},{% end %}

            {% end %}
          )
        )

        {% for idx in idxs %}
          {%
            idx_cols = idx.args[0]
            is_unique = false
            idx_name = nil

            for opt in idx.named_args
              if opt.name.stringify == "unique"
                is_unique = opt.value
              end
              if opt.name.stringify == "name"
                idx_name = opt.value
              end
            end
          %}
          @projection_database.exec %(CREATE{% if is_unique %} UNIQUE{% end %} INDEX {% if idx_name %}{{idx_name.id}}{% else %}{{table_name.id}}_{% for col, ci in idx_cols %}{{col.id}}{% if ci < idx_cols.size - 1 %}_{% end %}{% end %}_idx{% end %} ON "{{schema_name.id}}"."{{table_name.id}}"({% for col, ci in idx_cols %}{{col.id}}{% if ci < idx_cols.size - 1 %}, {% end %}{% end %}))
        {% end %}
      end

      def setup
        setup_table
      end
    end
  end
end
