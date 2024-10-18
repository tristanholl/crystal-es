module ES
  module QueueAdapters
    class InMemory < ES::Queue
      getter cursor : Int64 = 0
      @queue = Hash(Int64, ES::Queue::Entry).new
      @timeouts = Hash(Int64, Time).new

      # Prepares the queue
      def setup; end

      # Append event to queue
      def append(event : ES::Event)
        c = @cursor
        @cursor += 1
        qe = ES::Queue::Entry.new(c, 0, JSON.parse(event.header.to_json))
        @queue[c] = qe
      end

      # Archives a message from the queue
      def archive(msg_id : Int64)
        delete(msg_id)
      end

      # Delete item from queue
      def delete(msg_id : Int64)
        @queue.delete(msg_id)
        @timeouts.delete(msg_id)
      end

      # Reads messages from the queue
      protected def read(
        timeout : Time::Span = 10.seconds,
        count : Int32 = 1
      ) : Array(ES::Queue::Entry)
        message_array = Array(ES::Queue::Entry).new

        count.times do
          e = read_single(timeout)
          message_array << e unless e.nil?
        end

        message_array
      end

      # Read single item from queue and set visibility timeout
      protected def read_single(timeout : Time::Span = 10.seconds) : ES::Queue::Entry?
        msg_vt = Time.utc + timeout

        @queue.each do |k, e|
          if @timeouts.fetch(k, Time.utc) <= Time.utc
            @timeouts[k] = msg_vt
            return e
          end
        end
      end
    end
  end
end
