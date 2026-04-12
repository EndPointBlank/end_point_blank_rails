class StringTruncator
  DEFAULT_LIMIT = 1000
  DEFAULT_SUFFIX = "<truncated>"

  def self.truncate(str, limit: DEFAULT_LIMIT, suffix: DEFAULT_SUFFIX)
    return "" if str.nil?
    return str if str.bytesize <= limit

    suffix_bytes = suffix.bytesize
    max_bytes = limit - suffix_bytes

    truncated = str.byteslice(0, max_bytes)

    # Ensure valid UTF-8
    while !truncated.valid_encoding?
      truncated = truncated.byteslice(0, truncated.bytesize - 1)
    end

    truncated + suffix
  end
end