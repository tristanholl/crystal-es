module ES
  abstract class Queue
    abstract def read(name : String) : Array(ES::Queue::Entry)
    abstract def archive(name : String, msg_id : Int64)
    abstract def delete(name : String, msg_id : Int64)
    abstract def setup

    # Queue entry struct
    struct Entry
      getter msg_id : Int64
      getter read_ct : Int32

      # Using the Event header as message payload
      getter header : ES::Event::Header

      def initialize(
        @msg_id : Int64,
        @read_ct : Int32,
        header : JSON::Any
      )
        @header = ES::Event::Header.from_json(header.to_json)
      end
    end

    # TODO: Capacity 1 for non-parallel processing / above for parallel processing
    @channel = Channel(ES::Queue::Entry).new(100)

    # Listens for messages in the queue in a background process
    def listen(name : String, polling_sleep = 1000.milliseconds) : Channel(ES::Queue::Entry)
      spawn receive_loop(name, polling_sleep)
      @channel
    end

    # Receive loop to read messages from the queue
    private def receive_loop(name : String, polling_sleep : Time::Span)
      loop do
        read(name: name, timeout: 30, count: 10).each do |m|
          # Push received message to the channel
          @channel.send(m)
        end

        sleep polling_sleep
      end
    end
  end
end
