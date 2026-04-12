
module EndPointBlank
  module Writers
    class DirectWriter
      attr_accessor :url

      def initialize(url)
        @url = url
      end

      def write(list)
        auth = EndPointBlank::Authorization.header
        response = Excon.post(@url,
          headers: {'Authorization' => auth, 'Content-Type' => 'application/json'},
          body: {payload: list}.to_json
        )
      end
    end
  end
end
