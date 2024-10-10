module ES
  abstract class Queue
    abstract def read : Array(ES::Queue::Entry)
    abstract def archive(msg_id : Int64)
    abstract def delete(msg_id : Int64)

    struct Entry
      getter msg_id : Int64
      getter read_ct : Int32

      # Using the Event header as message payload
      getter header : ES::Event::Header

      def initialize(@msg_id : Int64, @read_ct : Int32, header : JSON::Any)
        @header = ES::Event::Header.from_json(header.to_json)
      end
    end

    @name = "Abstract"
    @channel = Channel(ES::Queue::Entry).new(100) # TODO: Capacity 1 for non-parallel processing / above for parallel processing

    getter name : String

    def listen(polling_sleep = 1.0) : Channel(ES::Queue::Entry)
      spawn receive_loop(polling_sleep)
      @channel
    end

    private def receive_loop(polling_sleep : Number)
      loop do
        read(timeout: 30, count: 10).each do |m|
          # Push received message to the channel
          @channel.send(m)
        end

        sleep polling_sleep
      end
    end
  end
end
