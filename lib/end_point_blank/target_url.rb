# frozen_string_literal: true

require "uri"

module EndPointBlank
  # The form of a caller's target URL that the SDK is allowed to use:
  # scheme, host, port and path, nothing else (sc-1469).
  #
  # The caller controls the URL, and its userinfo, query or fragment can
  # carry a secret. None of them is needed -- intake resolves the environment
  # from scheme, host, port and path alone, and its BaseUrl.normalize refuses
  # a URL carrying any of them (an empty `?` or `#` included), so sending them
  # would leak them to intake AND guarantee the mint fails. So every URL is
  # stripped here on the way in, and only the stripped form is sent to
  # intake, used as a cache or failure key, logged, or kept on an error.
  #
  # Built from the parsed parts, never by splitting the string, so an empty
  # `?` or `#` cannot slip through.
  #
  # Only http and https are accepted, because only they can name a provider.
  # Any other scheme is refused rather than rebuilt: Ruby parses it with a
  # scheme-specific class whose parts need not fit "scheme://host/path"
  # (URI::FTP's path has no leading slash, so "ftp://h:21/x" would come out
  # as "ftp://hx").
  module TargetUrl
    HTTP_SCHEMES = %w[http https].freeze
    private_constant :HTTP_SCHEMES

    # @param url [String, nil] the URL a caller is about to call
    # @return [String, nil] "scheme://host[:port]/path" (the scheme
    #   lowercased, IPv6 in brackets, the port only when it is not the scheme
    #   default, the path as given), or nil when url cannot be parsed, is not
    #   http or https, or has no host -- the caller must then refuse it
    #   without making any request.
    def self.strip(url)
      return nil if url.nil?

      uri = URI.parse(url.to_s)
      # URI lowercases the scheme, so "HTTPS://..." is accepted here too.
      return nil unless HTTP_SCHEMES.include?(uri.scheme)
      return nil if uri.host.to_s.empty?

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      "#{uri.scheme}://#{uri.host}#{port}#{uri.path}"
    rescue URI::Error
      nil
    end
  end
end
