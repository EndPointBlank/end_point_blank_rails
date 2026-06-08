require "json"

module EndPointBlank
  # Client-side masking. Applies configured rules to an outgoing payload's
  # maskable fields for the given record_type, then runs the optional user hook.
  # Payload keys are SYMBOLS matching the writers' payloads / intake wire keys.
  #
  # Rule shape (string-keyed-or-symbol-keyed hash):
  #   :target            — one of request_body, request_headers, path,
  #                        response_body, error_message; mapped to a wire key
  #                        per FIELD_MAP for the record_type.
  #   :path              — a JSONPath (constrained subset); may be nil/"".
  #   :regex             — a regex source string; may be nil/"".
  #   :replacement_value — literal replacement string.
  #
  # Matching semantics ("path scopes, regex matches within"):
  #   path only    — replace each node selected by the path entirely.
  #   regex only   — global regex substitution on every string leaf.
  #   path + regex — within each selected node, regex-substitute its string leaves.
  module Masking
    FIELD_MAP = {
      request: { "request_body" => :request, "request_headers" => :headers, "path" => :path },
      response: { "response_body" => :body },
      error: { "error_message" => :message },
      log: {}
    }.freeze

    # Targets whose wire value is a JSON string body (decode/apply/re-encode).
    JSON_TARGETS = %w[request_body response_body].freeze

    module_function

    def apply(payload, record_type, rules, hook)
      masked = (rules || []).reduce(payload) { |acc, rule| apply_rule(acc, record_type, rule) }
      hook ? hook.call(masked, record_type.to_s) : masked
    end

    def apply_rule(payload, record_type, rule)
      field_map = FIELD_MAP.fetch(record_type, {})
      target = rule[:target]
      key = field_map[target]
      return payload unless key && payload.key?(key)

      payload.merge(key => mask_field(payload[key], rule, target))
    end

    # Body targets: JSON string. Decode, apply on the decoded value, re-encode.
    # On non-JSON: path no-ops; regex (if present) applies to the raw string.
    # request_headers: a Hash. path applies; regex applies to string leaves.
    # path / error_message: plain strings — path no-ops, only regex applies.
    def mask_field(value, rule, target)
      case value
      when String
        if JSON_TARGETS.include?(target)
          begin
            decoded = JSON.parse(value)
          rescue JSON::ParserError
            return apply_to_raw_string(value, rule)
          end
          JSON.generate(apply_to_value(decoded, rule))
        else
          apply_to_raw_string(value, rule)
        end
      when Hash
        apply_to_value(value, rule)
      else
        value
      end
    end

    # A plain, non-JSON string target: path cannot apply (no-op); regex applies.
    def apply_to_raw_string(value, rule)
      re = compiled_regex(rule)
      return value unless re

      regex_replace_all(re, value, replacement(rule))
    end

    # Applies the rule to a structured value (decoded JSON or header Hash).
    def apply_to_value(value, rule)
      path = rule[:path] || rule["path"]
      tokens = parse_path(path)
      return value if tokens.nil? && path.is_a?(String) && path != ""

      re = compiled_regex(rule)
      repl = replacement(rule)

      if tokens && re
        # path + regex: select nodes, apply regex to leaves within each.
        transform(value, tokens) { |old| regex_replace_leaves(old, re, repl) }
      elsif tokens
        # path only: replace each selected node entirely.
        transform(value, tokens) { |_old| repl }
      elsif re
        # regex only: substitute across every string leaf.
        regex_replace_leaves(value, re, repl)
      else
        value
      end
    end

    def replacement(rule)
      (rule[:replacement_value] || rule["replacement_value"] || "...").to_s
    end

    # Compiles rule[:regex]; blank/nil/invalid ⇒ nil (regex step no-ops).
    def compiled_regex(rule)
      source = rule[:regex] || rule["regex"]
      return nil if source.nil? || source == ""

      Regexp.new(source)
    rescue RegexpError, TypeError
      nil
    end

    # Recurse over containers; substitute on every string leaf.
    def regex_replace_leaves(node, re, repl)
      case node
      when String then regex_replace_all(re, node, repl)
      when Hash then node.each_with_object({}) { |(k, v), out| out[k] = regex_replace_leaves(v, re, repl) }
      when Array then node.map { |e| regex_replace_leaves(e, re, repl) }
      else node
      end
    end

    # --- Replacement backreferences (shared contract) --------------------------
    #
    # In a regex substitution, replacement_value is a TEMPLATE. For each match we
    # build the replacement ourselves (NOT Ruby's native \N substitution):
    #   $$         → literal "$"
    #   $<digits>  → capture group N (full consecutive digit run); 0 = whole
    #                match; missing/non-participating group → "".
    #   lone/trailing $ before a non-digit → literal "$".
    # groups is 0-indexed: groups[0] = whole match, groups[n] = nth capture.

    def regex_replace_all(regexp, string, template)
      string.gsub(regexp) do
        m = Regexp.last_match
        groups = (0...m.size).map { |i| m[i] }
        expand(template, groups)
      end
    end

    def expand(template, groups)
      out = +""
      i = 0
      len = template.length
      while i < len
        ch = template[i]
        if ch != "$"
          out << ch
          i += 1
        elsif template[i + 1] == "$"
          out << "$"
          i += 2
        elsif template[i + 1] =~ /\d/
          j = i + 1
          j += 1 while j < len && template[j] =~ /\d/
          n = template[(i + 1)...j].to_i
          out << (groups[n] || "")
          i = j
        else
          out << "$"
          i += 1
        end
      end
      out
    end

    # --- Constrained JSONPath subset (mirrors intake's JsonPath) ---------------
    #
    # Tokens: [:child, name] / [:index, n] / [:wildcard] / [:descendant, name].
    # parse_path returns a token array, or nil for blank/unsupported/garbled
    # input (caller treats nil as "matches nothing"). Never raises.

    def parse_path(string)
      return nil unless string.is_a?(String)
      return nil unless string.start_with?("$")

      parse_tokens(string[1..], [])
    end

    def parse_tokens(rest, acc)
      return acc if rest.empty?

      if rest.start_with?("..")
        name, remaining = take_name(rest[2..])
        return nil if name.empty?

        parse_tokens(remaining, acc + [[:descendant, name]])
      elsif rest.start_with?(".*")
        parse_tokens(rest[2..], acc + [[:wildcard]])
      elsif rest.start_with?(".")
        name, remaining = take_name(rest[1..])
        return nil if name.empty?

        parse_tokens(remaining, acc + [[:child, name]])
      elsif rest.start_with?("[")
        result = parse_bracket(rest[1..])
        return nil unless result

        token, remaining = result
        parse_tokens(remaining, acc + [token])
      end
    end

    def parse_bracket(rest)
      if rest.start_with?("*]")
        [[:wildcard], rest[2..]]
      elsif rest.start_with?("'")
        parse_quoted(rest[1..], "'")
      elsif rest.start_with?('"')
        parse_quoted(rest[1..], '"')
      elsif (m = rest.match(/\A(\d+)\](.*)\z/m))
        [[:index, m[1].to_i], m[2]]
      end
    end

    def parse_quoted(rest, quote_char)
      name, remaining = rest.split("#{quote_char}]", 2)
      return nil if remaining.nil?

      [[:child, name], remaining]
    end

    # Consumes a leading [A-Za-z0-9_]+ run; returns [name, remaining].
    def take_name(string)
      m = string.match(/\A([A-Za-z0-9_]+)(.*)\z/m)
      return ["", string] unless m

      [m[1], m[2]]
    end

    # Walks value following tokens, replacing each fully-matched location with
    # the block's result and rebuilding parents immutably. Never raises.
    def transform(value, tokens, &block)
      return block.call(value) if tokens.empty?

      token, *rest = tokens
      case token[0]
      when :child
        key = token[1]
        return value unless value.is_a?(Hash) && value.key?(key)

        value.merge(key => transform(value[key], rest, &block))
      when :index
        i = token[1]
        return value unless value.is_a?(Array) && i >= 0 && i < value.length

        out = value.dup
        out[i] = transform(out[i], rest, &block)
        out
      when :wildcard
        case value
        when Hash then value.each_with_object({}) { |(k, v), o| o[k] = transform(v, rest, &block) }
        when Array then value.map { |e| transform(e, rest, &block) }
        else value
        end
      when :descendant
        descend(value, token[1], rest, &block)
      else
        value
      end
    end

    # Recursive descent: at this node and every nested node, any entry whose key
    # is `key` matches the remaining tokens.
    def descend(value, key, rest, &block)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), out|
          v = descend(v, key, rest, &block)
          out[k] = k == key ? transform(v, rest, &block) : v
        end
      when Array
        value.map { |e| descend(e, key, rest, &block) }
      else
        value
      end
    end
  end
end
