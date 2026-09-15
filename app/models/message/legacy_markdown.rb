class Message::LegacyMarkdown
  class << self
    def render(content)
      new(content).render
    end

    def non_mention_attachments(content)
      fragment = Nokogiri::HTML5.fragment(content.to_s)
      fragment.css("action-text-attachment").reject { |node| mention_attachment?(node) }.map(&:to_html).join("\n")
    end

    private
      def mention_attachment?(node)
        node["content-type"] == Message::Markdown::MENTION_CONTENT_TYPE
      end
  end

  def initialize(content)
    @fragment = Nokogiri::HTML5.fragment(content.to_s)
  end

  def render
    blocks(@fragment.children).presence || @fragment.text.strip
  end

  private
    def blocks(nodes)
      nodes.filter_map { |node| block(node).presence }.join("\n\n").strip
    end

    def block(node)
      return escaped_text(node.text) if node.text?

      case node.name
      when "p", "div", "section", "article", "figure"
        inline(node).strip
      when "h1", "h2", "h3", "h4", "h5", "h6"
        "#{'#' * node.name.delete_prefix('h').to_i} #{inline(node).strip}"
      when "blockquote"
        blocks(node.children).lines.map { |line| "> #{line}" }.join
      when "ul"
        list(node, marker: "-")
      when "ol"
        list(node, marker: :ordered)
      when "pre"
        code_block(node)
      when "hr"
        "---"
      when "br"
        "\n"
      when "action-text-attachment"
        attachment_markdown(node)
      else
        inline(node).strip
      end
    end

    def list(node, marker:)
      node.element_children.select { |child| child.name == "li" }.each_with_index.map do |item, index|
        prefix = marker == :ordered ? "#{index + 1}." : marker
        content = inline_children(item.children.reject { |child| %w[ul ol].include?(child.name) }).strip
        nested = item.element_children.select { |child| %w[ul ol].include?(child.name) }.map { |child| list(child, marker: child.name == "ol" ? :ordered : "-") }
        [ "#{prefix} #{content}", *nested.map { |text| text.lines.map { |line| "  #{line}" }.join } ].compact_blank.join("\n")
      end.join("\n")
    end

    def code_block(node)
      code = node.at_css("code") || node
      language = code["class"].to_s.split.find { |name| name.start_with?("language-") }.to_s.delete_prefix("language-")
      delimiter = code_delimiter(code.text)
      "#{delimiter}#{language}\n#{code.text.rstrip}\n#{delimiter}"
    end

    def inline(node)
      inline_children(node.children)
    end

    def inline_children(nodes)
      nodes.map { |child| inline_node(child) }.join
    end

    def inline_node(node)
      return escaped_text(node.text) if node.text?

      content = inline(node)
      case node.name
      when "strong", "b" then "**#{content}**"
      when "em", "i" then "*#{content}*"
      when "del", "s", "strike" then "~~#{content}~~"
      when "code" then inline_code(node.text)
      when "a"
        href = node["href"].to_s
        href.present? ? "[#{content}](<#{escaped_link_destination(href)}>)" : content
      when "br" then "\n"
      when "action-text-attachment" then attachment_markdown(node)
      when "ul", "ol" then "\n#{list(node, marker: node.name == 'ol' ? :ordered : '-')}\n"
      when "pre" then "\n#{code_block(node)}\n"
      else content
      end
    end

    def attachment_markdown(node)
      attachment = ActionText::Attachment.from_node(node)
      attachable = attachment.attachable
      return "@[#{attachable.name}]" if attachable.is_a?(User)

      node["href"].presence || node["url"].presence || attachment.to_plain_text.presence || node["filename"].presence || "[attachment]"
    rescue StandardError
      node["href"].presence || node["url"].presence || node["filename"].presence || "[attachment]"
    end

    def escaped_text(text)
      text.to_s.gsub(/[\\`*_\[\]]/) { |character| "\\#{character}" }
    end

    def inline_code(text)
      delimiter = code_delimiter(text)
      "#{delimiter}#{text}#{delimiter}"
    end

    def code_delimiter(text)
      "`" * ((text.to_s.scan(/`+/).map(&:length).max || 0) + 1)
    end

    def escaped_link_destination(href)
      href.gsub(/[<>]/) { |character| "\\#{character}" }
    end
end
