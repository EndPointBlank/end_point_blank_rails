require 'singleton'

module EndPointBlank
  module Writers
    module DelayedWriter
      def direct_writer
        @direct_writer ||= DirectWriter.new(url)
      end

      def start_threads
        @threads = []
        @queue = Queue.new

        2.times do
          @threads << Thread.new do
            loop do
              payload = @queue.pop
              payloads = [payload]
              while (payload = pop_additional) do
                payloads << payload
              end

              payloads.compact!
              while payloads.any? do
                list = payloads[0..5]
                response = direct_writer.write(list)
                if response.status < 299
                  on_success(response) if respond_to?(:on_success)
                else
                  on_failure(response) if respond_to?(:on_failure)
                end
                payloads = payloads - list
              end
            end
          end
        end
      end

      def pop_additional
        @queue.pop(true)
      rescue ThreadError
        nil
      end

      def enqueue(list)
        if list.is_a?(Array)
          list.each { |payload| @queue << payload }
        else
          @queue << list
        end
      end
    end
  end
end
