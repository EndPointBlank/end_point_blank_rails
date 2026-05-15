require_relative '../commands/http'

module EndPointBlank
  module Writers
    class DirectWriter
      attr_accessor :url

      def initialize(url)
        @url = url
      end

      def write(list)
        auth = EndPointBlank::Authorization.header
        EndPointBlank::Commands::Http.post(@url, auth, { payload: list })
      end
    end
  end
end
