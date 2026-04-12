require "rexml/document"
require "rexml/formatters/default"

class XmlTruncator
  MAX_BYTES = 10000
  MAX_DEPTH = 6
  MAX_CHILDREN = 20
  MAX_ATTRIBUTES = 20
  MAX_TEXT = 200
  TEXT_SUFFIX = "..."

  def self.truncate(xml, limit: MAX_BYTES)
    input = xml.to_s
    return "" if input.empty?
    return input if input.bytesize <= limit

    document = parse_xml(input)
    return StringTruncator.truncate(input, limit:, suffix: "<truncated/>") unless document&.root

    pruned_root = prune_element(document.root, depth: 0)
    output = render_element(pruned_root)
    return output if output.bytesize <= limit

    compact = compact_fallback(document.root.expanded_name)
    return compact if compact.bytesize <= limit

    "<truncated/>"
  end

  def self.parse_xml(input)
    REXML::Document.new(input)
  rescue REXML::ParseException
    nil
  end

  def self.prune_element(element, depth:)
    pruned = REXML::Element.new(element.expanded_name)

    element.attributes.each_with_index do |(name, value), idx|
      break if idx >= MAX_ATTRIBUTES
      pruned.add_attribute(name, truncate_text(value, max: 100))
    end

    if depth >= MAX_DEPTH
      pruned.add_element("truncated")
      return pruned
    end

    element_count = 0

    element.children.each do |child|
      case child
      when REXML::Element
        if element_count >= MAX_CHILDREN
          pruned.add_element("truncated")
          break
        end

        pruned.add_element(prune_element(child, depth: depth + 1))
        element_count += 1
      when REXML::CData
        pruned.add(REXML::CData.new(truncate_text(child.value)))
      when REXML::Text
        text = truncate_text(child.value)
        pruned.add_text(text) unless text.empty?
      end
    end

    pruned
  end

  def self.render_element(element)
    formatter = REXML::Formatters::Default.new
    output = +""
    formatter.write(element, output)
    output
  end

  def self.compact_fallback(root_name)
    "<#{root_name}><truncated/></#{root_name}>"
  end

  def self.truncate_text(text, max: MAX_TEXT)
    value = text.to_s
    return value if value.bytesize <= max

    value.byteslice(0, max - TEXT_SUFFIX.bytesize) + TEXT_SUFFIX
  end
end
