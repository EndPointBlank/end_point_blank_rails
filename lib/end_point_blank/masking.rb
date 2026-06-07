require "json"

module EndPointBlank
  # Client-side masking. Applies configured rules to an outgoing payload's
  # maskable fields for the given record_type, then runs the optional user hook.
  # Payload keys are SYMBOLS matching the writers' payloads / intake wire keys.
  module Masking
    FIELD_MAP = {
      request: { "request_body" => :request, "request_headers" => :headers, "path" => :path },
      response: { "response_body" => :body },
      error: { "error_message" => :message },
      log: {}
    }.freeze

    module_function

    def apply(payload, record_type, rules, hook)
      masked = (rules || []).reduce(payload) { |acc, rule| apply_rule(acc, record_type, rule) }
      hook ? hook.call(masked, record_type.to_s) : masked
    end

    def apply_rule(payload, record_type, rule)
      field_map = FIELD_MAP.fetch(record_type, {})

      (rule[:targets] || []).reduce(payload) do |acc, target|
        key = field_map[target]
        next acc unless key && acc.key?(key)

        acc.merge(key => mask_value(acc[key], rule))
      end
    end

    def mask_value(value, rule)
      case value
      when Hash then mask_hash(value, rule)
      when String then mask_string(value, rule)
      else value
      end
    end

    def mask_hash(hash, rule)
      hash.each_with_object({}) do |(k, v), out|
        out[k] =
          if rule[:match_type] == "key" && k.to_s.downcase == rule[:match_value].downcase
            rule[:mask_value]
          elsif rule[:match_type] == "regex" && v.is_a?(String)
            v.gsub(Regexp.new(rule[:match_value]), rule[:mask_value])
          else
            v
          end
      end
    end

    def mask_string(value, rule)
      if rule[:match_type] == "regex"
        value.gsub(Regexp.new(rule[:match_value]), rule[:mask_value])
      else
        mask_json_string(value, rule)
      end
    end

    def mask_json_string(value, rule)
      parsed = JSON.parse(value)
      JSON.generate(mask_json(parsed, rule[:match_value], rule[:mask_value]))
    rescue JSON::ParserError
      value
    end

    def mask_json(data, match_value, mask)
      case data
      when Hash
        data.each_with_object({}) do |(k, v), out|
          out[k] = k.to_s.downcase == match_value.downcase ? mask : mask_json(v, match_value, mask)
        end
      when Array
        data.map { |e| mask_json(e, match_value, mask) }
      else
        data
      end
    end
  end
end
