module ES
  module Queues
    class Postgres < ES::Queue
      def initialize(@db : DB::Database, @name : String)
      end

      def setup 
        m = Array(String).new
        m << %( CREATE EXTENSION pgmq cascade; )
      end

      def archive(msg_id : Int64)
        @db.query_one "SELECT * FROM pgmq.archive('#{@name}', #{msg_id})", as: {Bool}
      end

      def delete(msg_id : Int64)
        @db.query_one "SELECT * FROM pgmq.delete('#{@name}', #{msg_id})", as: {Bool}
      end

      protected def read(timeout = 10, count = 1) : Array(ES::Queue::Entry)
        message_array = Array(ES::Queue::Entry).new

        prepared_statement = @db.build("SELECT msg_id, read_ct, message FROM pgmq.read($1, $2, $3)")
        prepared_statement.query(@name, timeout, count) do |result|
          result.each do
            message_array << ES::Queue::Entry.new(result.read(Int64), result.read(Int32), result.read(JSON::Any))
          end
        end

        message_array
      end
    end
  end
end
