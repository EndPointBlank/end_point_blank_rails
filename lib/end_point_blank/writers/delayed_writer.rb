# frozen_string_literal: true

require "singleton"

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
      # Payloads per outbound request. One request per payload would multiply
      # the host application's outbound traffic by its own request rate; the
      # drain exists to amortise that.
      BATCH_SIZE = 6
      # Fallback thread count used when Configuration#worker_count is unset,
      # preserving the previously-hardcoded pool size.
      DEFAULT_WORKER_COUNT = 2
      # Applied after a worker iteration raises, doubling with each consecutive
      # failure up to the cap. Surviving a defect must not mean retrying as fast
      # as the CPU allows: a persistent failure should read as a slow, loud
      # retry, not as a silent hot loop.
      WORKER_BACKOFF_SECONDS = 0.1
      MAX_WORKER_BACKOFF_SECONDS = 30

      def direct_writer
        @direct_writer ||= DirectWriter.new(url)
      end

      def queue
        @queue ||= Queue.new
      end

      def worker_count
        EndPointBlank::Configuration.instance.worker_count || DEFAULT_WORKER_COUNT
      end

      def start_threads
        @threads = []

        worker_count.times do
          @threads << Thread.new { run_worker }
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

      # Logs a delivery or worker-loop error, through the same seam. Everything
      # a worker recovers from goes through here: recovering quietly would trade
      # one silent failure for another.
      def log_error(message)
        EndPointBlank.logger.error(message)
      end

      private

      # The body of a worker thread.
      #
      # A thread that dies here takes every future payload in the process with
      # it - silently, until a restart - which is far worse than losing the
      # batch in flight. So the loop catches every StandardError, says what it
      # caught, and carries on.
      #
      # What it deliberately does not catch is anything outside StandardError:
      # SystemExit, Interrupt, SignalException, NoMemoryError. Those mean the
      # process itself is going down or is already broken, and a telemetry
      # worker has no business arguing with that.
      def run_worker
        consecutive_failures = 0

        loop do
          drain_once
          consecutive_failures = 0
        rescue StandardError => e
          consecutive_failures += 1
          note_worker_error(e, consecutive_failures)
          sleep(worker_backoff(consecutive_failures))
        end
      end

      # Blocks for the next payload, then takes everything else already waiting
      # so a burst leaves as a few batches rather than one request per payload.
      #
      # The batches are cut by position, and that is the point. This used to
      # take a prefix and then remove it with `payloads -= list`, and Array#-
      # removes every element *equal to* one in the batch rather than the ones
      # actually sent: seven byte-identical payloads with a batch size of six
      # meant six delivered and all seven gone. Nothing counted the loss and the
      # queue drained normally, so it read as if nothing had happened.
      #
      # Equal payloads are ordinary, not exotic. Payloads are hashes, and two
      # requests to the same endpoint from the same application in the same
      # environment differ only in high-cardinality fields; `sent_at` at
      # millisecond precision is not a reliable discriminator at ingest volumes.
      # Slicing by index makes equality irrelevant rather than merely handled.
      def drain_once
        payloads = [queue.pop]
        while (payload = pop_additional)
          payloads << payload
        end

        payloads.compact!
        payloads.each_slice(BATCH_SIZE) { |list| deliver_batch(list) }
      end

      def deliver_batch(list)
        response = direct_writer.write(list)
        return note_unanswered(list) if response.nil?

        if response.status < 299
          on_success(response) if respond_to?(:on_success)
        elsif respond_to?(:on_failure)
          on_failure(response)
        end
      end

      # nil is what Commands::Http returns once its retries are exhausted. It is
      # not a status - it is the absence of an answer - so it is reported rather
      # than compared: on_failure hears about it with nil, meaning "nothing
      # answered", and the batch it cost us is named in the log either way.
      def note_unanswered(list)
        log_error(
          "[EndPointBlank] no response from #{url} after retries; " \
          "#{list.size} payload(s) in that batch are lost"
        )
        on_failure(nil) if respond_to?(:on_failure)
      end

      def note_worker_error(error, consecutive_failures)
        log_error(
          "[EndPointBlank] send worker recovered from #{error.class}: #{error.message} " \
          "(consecutive failure #{consecutive_failures}); the batch in flight is lost, " \
          "retrying in #{worker_backoff(consecutive_failures).round(1)}s at #{Array(error.backtrace).first}"
        )
      end

      def worker_backoff(consecutive_failures)
        [
          WORKER_BACKOFF_SECONDS * (2**(consecutive_failures - 1)),
          MAX_WORKER_BACKOFF_SECONDS
        ].min
      end

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
