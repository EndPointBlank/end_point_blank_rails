require 'singleton'

module EndPointBlank
  module Writers
    # Drains a background send queue with a fixed pool of worker threads.
    #
    # The queue is bounded (see MAX_QUEUE_SIZE) so that during an intake
    # outage - when the worker threads can't drain as fast as the host
    # application enqueues payloads - memory usage stays capped instead of
    # growing without bound toward an OOM. When the queue is full, the
    # *oldest* item is dropped to make room for the newest one, and a
    # warning is logged, throttled so a sustained outage does not itself
    # become a logging flood.
    module DelayedWriter
      MAX_QUEUE_SIZE = 1000
      WARN_THROTTLE_SECONDS = 30

      def direct_writer
        @direct_writer ||= DirectWriter.new(url)
      end

      def queue
        @queue ||= Queue.new
      end

      def start_threads
        @threads = []

        2.times do
          @threads << Thread.new do
            loop do
              payload = queue.pop
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
        queue.pop(true)
      rescue ThreadError
        nil
      end

      def enqueue(list)
        items = list.is_a?(Array) ? list : [list]
        items.each { |payload| enqueue_one(payload) }
      end

      # Logs a drop warning. Overridable/stubbable in tests; routed through
      # the pluggable EndPointBlank.logger seam (this lib is fire-and-forget
      # and must never raise).
      def log_warning(message)
        EndPointBlank.logger.warn(message)
      end

      private

      def enqueue_mutex
        @enqueue_mutex ||= Mutex.new
      end

      def enqueue_one(payload)
        enqueue_mutex.synchronize do
          drop_oldest_and_note if queue.size >= MAX_QUEUE_SIZE
          queue << payload
        end
      end

      def drop_oldest_and_note
        pop_additional
        note_drop
      end

      def note_drop
        @dropped_since_last_warning = (@dropped_since_last_warning || 0) + 1
        now = Time.now
        return if @last_drop_warning_at && (now - @last_drop_warning_at) < WARN_THROTTLE_SECONDS

        warn_dropped_items(now)
      end

      def warn_dropped_items(now)
        dropped = @dropped_since_last_warning
        @dropped_since_last_warning = 0
        @last_drop_warning_at = now

        log_warning(
          "[EndPointBlank] send queue full (max #{MAX_QUEUE_SIZE}); " \
          "dropped #{dropped} oldest item(s) since last warning"
        )
      end
    end
  end
end
