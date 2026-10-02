# frozen_string_literal: true

require_relative "../page"

module EndPointBlank
  module Management
    # The management API's resources, each reached from a {Client} (or a
    # {ManagedClient} view) rather than built directly.
    #
    # Every method answers what the API sent, decoded from JSON into Hashes
    # with String keys: a single resource's +data+, a {Page} for a list, and
    # <tt>{"id" => ..., "deleted" => true}</tt> for a delete. Optional keyword
    # arguments left nil are not sent.
    module Resources
      # Shared plumbing: paths, list pages and auto-paging.
      class Base
        MAX_LIMIT = 100

        def initialize(transport, prefix = "")
          @transport = transport
          @prefix = prefix
        end

        def inspect
          "#<#{self.class.name} prefix=#{@prefix.inspect}>"
        end

        # One path segment, percent-escaped. An empty id is refused, so it can
        # never turn a "get one" into a "list all".
        def self.escape(segment)
          value = segment.to_s
          raise ArgumentError, "an id must be a non-empty String" if value.empty?

          value.b.gsub(/[^A-Za-z0-9\-._~]/n) { |char| format("%%%02X", char.ord) }
        end

        private

        # "/segment/escaped-id/..." under this resource's prefix. Every
        # argument is one path segment (see {.escape}).
        def path(*segments)
          @prefix + segments.map { |segment| "/#{escape(segment)}" }.join
        end

        def escape(segment)
          self.class.escape(segment)
        end

        def get_data(path, query = nil)
          data(@transport.request("GET", path, query: query))
        end

        def post_data(path, body, idempotency_key)
          data(@transport.request("POST", path, body: body, idempotency_key: idempotency_key))
        end

        def patch_data(path, body)
          data(@transport.request("PATCH", path, body: body))
        end

        def delete_data(path)
          data(@transport.request("DELETE", path))
        end

        def data(body)
          body.is_a?(Hash) && body.key?("data") ? body["data"] : body
        end

        # One page of a list. +filters+ with a nil value are not sent.
        def list_page(path, limit, after, filters = {})
          check_limit(limit)
          query = compact(filters.merge(limit: limit, after: after))
          Page.from_body(@transport.request("GET", path, query: query))
        end

        # Every item of a list, fetching pages as it goes. With a block,
        # yields each item and answers nil; without one, answers an
        # Enumerator (lazy: no request is made until it is iterated).
        def each_item(path, limit, filters = {}, &block)
          check_limit(limit)
          enumerator = Enumerator.new { |yielder| each_page_item(yielder, path, limit, filters) }
          return enumerator unless block

          enumerator.each(&block)
          nil
        end

        def each_page_item(yielder, path, limit, filters)
          after = nil
          loop do
            page = list_page(path, limit, after, filters)
            page.each { |item| yielder << item }
            break unless page.next_page?

            after = page.next_cursor
          end
        end

        def check_limit(limit)
          return if limit.nil?
          return if limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)

          raise ArgumentError, "limit must be an Integer from 1 to #{MAX_LIMIT}, got #{limit.inspect}"
        end

        def compact(hash)
          hash.reject { |_key, value| value.nil? }
        end
      end
    end
  end
end
