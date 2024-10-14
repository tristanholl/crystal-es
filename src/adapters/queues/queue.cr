module ES
  abstract class Queue
    abstract def read(timeout : Time::Span, count : Int32) : Array(ES::Queue::Entry)
    abstract def archive(msg_id : Int64)
    abstract def delete(msg_id : Int64)
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

    # Initialize queue with name
    def initialize(@name : String); end

    # TODO: Capacity 1 for non-parallel processing / above for parallel processing
    @channel = Channel(ES::Queue::Entry).new(100)

    # Listens for messages in the queue in a background process
    def listen(polling_sleep = 1000.milliseconds, visibility_timeout = 30.seconds) : Channel(ES::Queue::Entry)
      spawn receive_loop(polling_sleep, visibility_timeout)
      @channel
    end

    # Receive loop to read messages from the queue
    private def receive_loop(polling_sleep : Time::Span, visibility_timeout : Time::Span)
      loop do
        read(timeout: visibility_timeout, count: 10).each do |m|
          # Push received message to the channel
          @channel.send(m)
        end

        sleep polling_sleep
      end
    end
  end
end
