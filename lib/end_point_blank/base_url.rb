# frozen_string_literal: true

module EndPointBlank
  # Resolves the base URL the caller used -- scheme, host and port -- from a
  # Rack env.
  #
  # This deliberately does not go through Rack::Request#host / #scheme / #port.
  # Rack, Express, the servlet spec and Plug each resolve "host" differently
  # (Rack takes the last X-Forwarded-Host hop, Express the first, WSGI and Plug
  # neither), which is precisely why the same request produced five different
  # answers across the five clients. The env is read directly so that this
  # algorithm is the same one implemented in the JS, Python, Java and Elixir
  # libraries.
  #
  # Forwarded headers are honored when `trust_proxy_headers` is on, which it is
  # by default: `host` was already caller-controlled in every client (all five
  # read the Host header), so this opens no new hole for the field that matters
  # most, and taking the LAST hop means that behind a proxy that appends, the
  # value is the proxy's own observation rather than anything the caller
  # planted. A directly-exposed deployment -- where nothing sits in front to
  # overwrite the headers -- can set the flag to false, and then only the
  # connection and the Host header are consulted.
  #
  # The flag arrives as an argument rather than being read from Configuration
  # here, so that this module stays framework- and configuration-free and both
  # states are directly testable.
  module BaseUrl
    HOSTNAME = /\A[a-z0-9._-]+\z/
    IPV6 = /\A\[[0-9a-f:.]+\]\z/
    SCHEME = /\A[a-z][a-z0-9+.-]{0,31}\z/
    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    module_function

    # Returns a Hash carrying only the fields that resolved to a usable value.
    # A field that could not be resolved is absent, never nil: the receiver has
    # to be able to tell "this SDK did not report a port" from "the port is
    # null".
    #
    # With trust_proxy_headers: false the three X-Forwarded-* headers are not
    # read at all, so the request is never treated as proxied and the
    # connection's scheme and port stay evidence.
    def from_rack_env(env, trust_proxy_headers: true)
      return {} unless env.is_a?(Hash)

      forwarded_proto = trust_proxy_headers ? last_hop(env["HTTP_X_FORWARDED_PROTO"]) : nil
      forwarded_host = trust_proxy_headers ? last_hop(env["HTTP_X_FORWARDED_HOST"]) : nil
      forwarded_port = trust_proxy_headers ? last_hop(env["HTTP_X_FORWARDED_PORT"]) : nil
      proxied = !(forwarded_proto.nil? && forwarded_host.nil? && forwarded_port.nil?)

      host_part, authority_port = split_authority(forwarded_host || env["HTTP_HOST"] || env["SERVER_NAME"])

      scheme = clean_scheme(forwarded_proto || (proxied ? nil : env["rack.url_scheme"]))
      host = clean_host(host_part)
      port = clean_port(forwarded_port || authority_port || (proxied ? nil : env["SERVER_PORT"]), scheme)

      resolved = {}
      resolved[:scheme] = scheme if scheme
      resolved[:host] = host if host
      resolved[:port] = port if port
      resolved
    end

    # A proxy that appends writes its own observation last. A proxy that
    # overwrites (nginx, Caddy, ALB) emits one value, where first and last are
    # the same thing.
    def last_hop(value)
      return nil unless value.is_a?(String)

      hops = value.split(",").map(&:strip).reject(&:empty?)
      hops.last
    end

    # "api.example.com:8443" -> ["api.example.com", "8443"]
    # "[2001:db8::1]:8443"   -> ["[2001:db8::1]", "8443"]
    def split_authority(value)
      return [nil, nil] unless value.is_a?(String)

      authority = value.strip
      if authority.start_with?("[")
        head, bracket, tail = authority.partition("]")
        return [nil, nil] if bracket.empty?

        ["#{head}]", tail.start_with?(":") ? tail[1..] : nil]
      elsif authority.count(":") == 1
        host, _, port = authority.partition(":")
        [host, port]
      else
        [authority, nil]
      end
    end

    # Normalize, then validate. "HTTPS" and "https:" both have to reach intake
    # as "https": JS's location.protocol and Node's URL#protocol keep the
    # colon, nothing pins the case, and intake never rewrites a stored row --
    # two spellings of the same scheme would split the dominant-triple
    # grouping forever. delete_suffix removes one colon, not all of them, so
    # "https::" still fails the shape check rather than sneaking through.
    def clean_scheme(value)
      return nil unless value.is_a?(String)

      scheme = value.strip.downcase.delete_suffix(":")
      scheme.match?(SCHEME) ? scheme : nil
    end

    def clean_host(value)
      return nil unless value.is_a?(String)

      host = value.strip.downcase
      return nil if host.empty?

      host.match?(HOSTNAME) || host.match?(IPV6) ? host : nil
    end

    def clean_port(value, scheme)
      port = Integer(value.to_s.strip, 10, exception: false)
      return nil if port.nil? || port < 1 || port > 65_535
      return nil if DEFAULT_PORTS[scheme] == port

      port
    end
  end
end
