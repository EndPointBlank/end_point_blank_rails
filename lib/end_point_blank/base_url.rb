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

      forwarded_scheme = trust_proxy_headers ? clean_scheme(last_hop(env["HTTP_X_FORWARDED_PROTO"])) : nil
      forwarded_host_part, forwarded_host_authority_port =
        trust_proxy_headers ? split_authority(last_hop(env["HTTP_X_FORWARDED_HOST"])) : [nil, nil]
      forwarded_host = clean_host(forwarded_host_part)
      forwarded_port = trust_proxy_headers ? parse_port(last_hop(env["HTTP_X_FORWARDED_PORT"])) : nil

      # Evidence is judged AFTER validation, not on raw header presence: a
      # malformed header (e.g. "X-Forwarded-Port: not-a-port") parses to
      # nothing and so must never count as proxy evidence, or an
      # unauthenticated caller could blank an otherwise-valid field just by
      # sending garbage.
      #
      # Only a forwarded scheme or port counts as evidence strong enough to
      # distrust the raw connection. A forwarded Host alone does not: some
      # proxies rewrite only the Host header and pass scheme/port through
      # unchanged, so a valid X-Forwarded-Host by itself says nothing about
      # whether the connection's own scheme/port belong to the proxy or the
      # caller.
      proxied = !forwarded_scheme.nil? || !forwarded_port.nil?

      # A malformed X-Forwarded-Host (wrong shape, or too long -- see
      # clean_host) gets the same treatment as a malformed proto or port: it
      # is ignored entirely and falls back to the direct Host header, exactly
      # as if the header were absent, rather than leaving host unresolved.
      host_part, authority_port =
        if forwarded_host
          [forwarded_host_part, forwarded_host_authority_port]
        else
          split_authority(env["HTTP_HOST"] || env["SERVER_NAME"])
        end

      scheme = forwarded_scheme || (proxied ? nil : clean_scheme(env["rack.url_scheme"]))
      host = forwarded_host || clean_host(host_part)
      port_candidate = forwarded_port ||
                       parse_port(authority_port) ||
                       (proxied ? nil : parse_port(env["SERVER_PORT"]))
      port = usable_port(port_candidate, scheme)

      resolved = {}
      resolved[:scheme] = scheme if scheme
      resolved[:host] = host if host
      resolved[:port] = port if port
      resolved
    end

    # The hostname alone, for the authorize path.
    #
    # Deliberately NOT from_rack_env(env)[:host]: reads the Host header only,
    # never the forwarded chain, however trust_proxy_headers is set. The
    # value feeds `target_hostname` and the access-token cache key, and the
    # portal resolves an application environment from it -- a value matching
    # no registered row is a hard 422 with no fallback, not a cache miss.
    #
    # Composed from the same split_authority/clean_host pair from_rack_env
    # uses, so IPv6 bracketing, lowercasing, and shape and length validation
    # are identical between the two; only the authority's source differs.
    def hostname_from_rack_env(env)
      return nil unless env.is_a?(Hash)

      host_part, _authority_port = split_authority(env["HTTP_HOST"] || env["SERVER_NAME"])
      clean_host(host_part)
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

    # DNS caps a hostname at 253 characters, and the receiving column is
    # varchar(255). No web-server adapter validates the length of
    # X-Forwarded-Host, so without this a caller could make the SDK report an
    # arbitrarily long value; dropped, not truncated, because a truncated
    # hostname is a plausible-looking WRONG one and the portal reads `host`
    # verbatim to assemble a base URL.
    def clean_host(value)
      return nil unless value.is_a?(String)

      host = value.strip.downcase
      return nil if host.empty? || host.bytesize > 253

      host.match?(HOSTNAME) || host.match?(IPV6) ? host : nil
    end

    # Numeric validation only -- 1..65535, nothing scheme-aware. Used both to
    # decide whether a forwarded/authority port counts as a usable value and
    # as a port candidate; default-port omission happens exactly once, in
    # usable_port, against the FINAL resolved scheme, so it can never be
    # skipped just because the scheme happened to resolve from a different
    # source than the port did.
    def parse_port(value)
      port = Integer(value.to_s.strip, 10, exception: false)
      return nil if port.nil? || port < 1 || port > 65_535

      port
    end

    # A port is reported only when it can be classified against a resolved
    # scheme. With no scheme, "default" is meaningless, so an unclassifiable
    # port is withheld entirely rather than guessed at -- the same origin must
    # never be reportable two ways depending on which headers happened to
    # arrive.
    def usable_port(candidate, scheme)
      return nil if candidate.nil? || scheme.nil?
      return nil if DEFAULT_PORTS[scheme] == candidate

      candidate
    end
  end
end
