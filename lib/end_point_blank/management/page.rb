# frozen_string_literal: true

module EndPointBlank
  module Management
    # One page of a management API list: the items (+data+, Hashes with String
    # keys, as the API sent them) and the cursor for the next page, nil on the
    # last one. Enumerable over its items.
    #
    # Pass +next_cursor+ as +after:+ to the same list call for the next page,
    # or use the resource's +each+ to walk every page.
    class Page
      include Enumerable

      # @return [Array<Hash>]
      attr_reader :data
      # @return [String, nil]
      attr_reader :next_cursor

      def initialize(data:, next_cursor:)
        @data = data
        @next_cursor = next_cursor
      end

      # Builds a page from a list answer, <tt>{"data" => [...], "next_cursor" => ...}</tt>.
      def self.from_body(body)
        body = {} unless body.is_a?(Hash)
        new(data: Array(body["data"]), next_cursor: body["next_cursor"])
      end

      def each(&block)
        return enum_for(:each) unless block

        data.each(&block)
        self
      end

      # Whether there is a page after this one.
      def next_page?
        !next_cursor.nil? && !next_cursor.empty?
      end

      def size
        data.size
      end

      def empty?
        data.empty?
      end

      def inspect
        "#<#{self.class.name} size=#{size} next_cursor=#{next_cursor.inspect}>"
      end
    end
  end
end
