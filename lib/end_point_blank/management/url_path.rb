# frozen_string_literal: true

module EndPointBlank
  module Management
    # URL string helpers for the management client.
    module UrlPath
      SLASH = "/".ord

      # +text+ without trailing slashes. One backward scan over the bytes, not
      # a regex, so its cost is linear however the input is shaped.
      def self.strip_trailing_slashes(text)
        stop = text.bytesize
        stop -= 1 while stop.positive? && text.getbyte(stop - 1) == SLASH
        text.byteslice(0, stop)
      end
    end
  end
end
