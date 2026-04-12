require "json"

class FastJsonTruncator
  MAX_BYTES  = 10000
  MAX_DEPTH  = 5
  MAX_LIST   = 20
  MAX_STRING = 200
  MAX_KEYS   = 20

  def self.truncate(data, limit = MAX_BYTES)
    pruned = prune(data, 0)
    json = JSON.generate(pruned)
    ensure_limit(json, limit)
  end

  def self.prune(value, depth)
    return "[truncated]" if depth > MAX_DEPTH

    case value
    when Hash
      result = {}
      value.each_with_index do |(k, v), i|
        break if i >= MAX_KEYS
        result[k] = prune(v, depth + 1)
      end
      result

    when Array
      value.first(MAX_LIST).map { |v| prune(v, depth + 1) }

    when String
      if value.bytesize > MAX_STRING
        value.byteslice(0, MAX_STRING) + "..."
      else
        value
      end

    else
      value
    end
  end

  def self.ensure_limit(json, limit)
    return json if json.bytesize <= limit

    truncated = json.byteslice(0, limit - 20)
    truncated + '...,"truncated":true}'
  end
end