class Message::Markdown
  SOURCE_LIMIT = 50_000
  MENTION_CONTENT_TYPE = "application/vnd.campfire.mention"

  MARKDOWN_TAGS = %w[
    a blockquote br code del em h1 h2 h3 h4 h5 h6 hr input li ol p pre
    strong table tbody td th thead tr ul
  ].freeze
  MARKDOWN_ATTRIBUTES = %w[
    align checked class disabled href rel start target title type
  ].freeze
  PRESENTATION_TAGS = (MARKDOWN_TAGS + %w[
    action-text-attachment div figure figcaption img span
  ]).freeze
  PRESENTATION_ATTRIBUTES = (MARKDOWN_ATTRIBUTES + ActionText::Attachment::ATTRIBUTES + %w[
    alt aria-hidden data-turbo-frame data-user-id draggable height src width
  ]).uniq.freeze

  MENTION_TOKEN_PATTERN = /(?<!\\)@\[(?<name>[^\[\]\r\n]+)\]/
  SKIPPED_MENTION_ANCESTORS = %w[ a code pre ].freeze
  SKIPPED_ICON_ANCESTORS = %w[ a action-text-attachment code pre ].freeze
  ALLOWED_CLASSES = %w[ contains-task-list markdown-body task-list-item ].freeze
  LANGUAGE_CLASS_PATTERN = /\Alanguage-[a-zA-Z0-9_+.-]+\z/
  BLOCK_TAGS = %w[ blockquote h1 h2 h3 h4 h5 h6 li ol p pre table tr ul ].freeze
  CELL_TAGS = %w[ td th ].freeze
  ICON_ALT_PATTERN = /\A:(?<name>[a-z0-9_]+):\z/
  AVATAR_SRC_PATTERN = %r{\A/users/[^/?#]+/avatar([?#]|\z)}

  class << self
    def render(source, room:)
      new(source, room:).render
    end

    def mention_token(name)
      "@[#{name}]" if name.present? && !name.match?(/[\[\]\r\n]/)
    end

    def plain_text(content)
      expanded = content.render_attachments(with_full_attributes: false, &:to_plain_text)
      fragment = Nokogiri::HTML5.fragment(expanded.to_html)
      text = fragment.children.map { |node| plain_text_from(node) }.join

      text.lines.map(&:rstrip).join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    # Markdown is sanitized before it is persisted. Presentation adds only
    # server-rendered Action Text attachments, then sanitizes once more with the
    # attributes required by the existing mention partial.
    #
    # Icon sources are rewritten from the :name: in their alt text, so a stored
    # body keeps rendering after a digest change or an asset host move. Every
    # image is checked: mention avatars are allowlisted by route path and
    # anything else is dropped.
    def sanitize_presentation(html)
      safe = sanitize(html, tags: PRESENTATION_TAGS, attributes: PRESENTATION_ATTRIBUTES)
      return safe unless safe.include?("<img")

      fragment = Nokogiri::HTML5.fragment(safe)
      fragment.css("img").each do |img|
        if (brand = brand_from_alt(img["alt"])) && (url = Icons.brand_image_urls[brand.name])
          img["src"] = url
        elsif !avatar_src?(img["src"])
          img.remove
        end
      end
      fragment.to_html
    end

    private
      # The icon name carried in alt text, e.g. ":openai:". Aliases resolve to
      # their brand; anything else is not an icon.
      def brand_from_alt(alt)
        name = alt.to_s.match(ICON_ALT_PATTERN)&.[](:name)
        icon = name && Icons.find(name)

        icon if icon.is_a?(Icons::Brand)
      end

      # A same-origin avatar path, or the same path served from the configured
      # asset host (plain string, trailing slash, protocol-relative, %d
      # wildcard, or Proc alike). Anything else is dropped.
      def avatar_src?(src)
        uri = URI.parse(src.to_s)
        return false unless uri.path.to_s.match?(AVATAR_SRC_PATTERN)
        return true if uri.scheme.nil? && uri.host.nil?

        uri.scheme.to_s.downcase.in?(%w[ http https ]) && asset_host_pattern&.match?(uri.host.to_s) || false
      rescue URI::InvalidURIError
        false
      end

      def asset_host_pattern
        configured = Rails.configuration.action_controller.asset_host
        configured = configured.arity.abs >= 2 ? configured.call("/users/x/avatar", nil) : configured.call("/users/x/avatar") if configured.respond_to?(:call)
        return if configured.blank?

        host = configured.to_s.sub(%r{\A(https?:)?//}i, "").sub(%r{[/?#].*\z}, "")
        Regexp.new("\\A#{Regexp.escape(host).gsub("%d", "\\d+")}\\z", Regexp::IGNORECASE)
      rescue StandardError
        nil
      end

      def sanitize(html, tags:, attributes:)
        sanitizer_class.new.sanitize(html, tags:, attributes:)
      end

      def sanitizer_class
        ActionText::ContentHelper.sanitizer.class
      end

      def plain_text_from(node)
        return node.text if node.text?
        return "\n" if node.name == "br"
        return node["alt"].to_s if node.name == "img" && (brand_from_alt(node["alt"]) || node["class"].to_s.split.include?("icon--brand"))

        text = node.children.map { |child| plain_text_from(child) }.join
        return "#{text}\t" if CELL_TAGS.include?(node.name)

        BLOCK_TAGS.include?(node.name) ? "#{text}\n\n" : text
      end
  end

  def initialize(source, room:)
    @source = source.to_s
    @room = room
  end

  def render
    protected_source, mention_tokens = protect_mention_tokens
    rendered_html = Commonmarker.to_html(
      protected_source,
      options: {
        render: { hardbreaks: false, github_pre_lang: false, unsafe: false },
        extension: {
          autolink: true,
          header_ids: nil,
          shortcodes: false,
          strikethrough: true,
          table: true,
          tagfilter: true,
          tasklist: true
        }
      },
      plugins: { syntax_highlighter: nil }
    )

    fragment = Nokogiri::HTML5.fragment(
      self.class.send(:sanitize, rendered_html, tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRIBUTES)
    )

    constrain_generated_markup(fragment)
    restore_mention_tokens_in_attributes(fragment, mention_tokens)
    restore_mention_tokens(fragment, mention_tokens)
    expand_icon_shortcodes(fragment)
    fragment.to_html
  end

  private
    def protect_mention_tokens
      tokens = {}
      prefix = "CAMPFIREMENTION#{SecureRandom.hex(12).upcase}"
      index = 0

      protected_source = @source.gsub(MENTION_TOKEN_PATTERN) do |token|
        placeholder = "#{prefix}#{index}TOKEN"
        tokens[placeholder] = { token:, name: Regexp.last_match[:name] }
        index += 1
        placeholder
      end

      [ protected_source, tokens ]
    end

    def constrain_generated_markup(fragment)
      fragment.css("[class]").each do |node|
        classes = node["class"].split.select { |name| ALLOWED_CLASSES.include?(name) || name.match?(LANGUAGE_CLASS_PATTERN) }
        classes.any? ? node["class"] = classes.join(" ") : node.remove_attribute("class")
      end

      fragment.css("input").each do |input|
        if input["type"] == "checkbox"
          input["disabled"] = "disabled"
          input.remove_attribute("value")
        else
          input.remove
        end
      end

      fragment.css("a[href]").each do |link|
        if link["href"].blank?
          link.remove_attribute("href")
        else
          link["target"] = "_blank"
          link["rel"] = "nofollow noopener noreferrer"
        end
      end
    end

    def restore_mention_tokens(fragment, mention_tokens)
      return if mention_tokens.empty?

      mentionees = unique_active_room_members(mention_tokens.values.pluck(:name))
      placeholders_pattern = Regexp.union(mention_tokens.keys)

      fragment.xpath(".//text()").each do |text_node|
        next unless text_node.content.match?(placeholders_pattern)

        replacement = Nokogiri::XML::DocumentFragment.new(fragment.document)
        remaining = text_node.content

        while (match = placeholders_pattern.match(remaining))
          replacement.add_child(Nokogiri::XML::Text.new(remaining[0...match.begin(0)], fragment.document)) if match.begin(0).positive?
          mention = mention_tokens.fetch(match[0])
          replacement.add_child(mention_node(fragment, text_node, mention, mentionees))
          remaining = remaining[match.end(0)..]
        end

        replacement.add_child(Nokogiri::XML::Text.new(remaining, fragment.document)) if remaining.present?
        text_node.replace(replacement)
      end
    end

    def restore_mention_tokens_in_attributes(fragment, mention_tokens)
      return if mention_tokens.empty?

      fragment.css("*").each do |node|
        node.attribute_nodes.each do |attribute|
          mention_tokens.each do |placeholder, mention|
            attribute.value = attribute.value.gsub(placeholder, mention[:token])
          end
        end
      end
    end

    def unique_active_room_members(names)
      @room.users.active.where(name: names.uniq).group_by(&:name).transform_values do |users|
        users.one? ? users.first : nil
      end
    end

    def mention_node(fragment, text_node, mention, mentionees)
      user = mentionees[mention[:name]] unless skipped_mention_context?(text_node)

      if user
        attachment_html = ActionText::Attachment.from_attachable(
          user, content_type: MENTION_CONTENT_TYPE
        ).to_html
        Nokogiri::HTML5.fragment(attachment_html).children.first
      else
        Nokogiri::XML::Text.new(mention[:token], fragment.document)
      end
    end

    def skipped_mention_context?(text_node)
      text_node.ancestors.any? { |ancestor| SKIPPED_MENTION_ANCESTORS.include?(ancestor.name) }
    end

    def expand_icon_shortcodes(fragment)
      fragment.xpath(".//text()").each do |text_node|
        next unless text_node.content.match?(Icons::SHORTCODE_PATTERN)
        next if skipped_icon_context?(text_node)

        replacement = Nokogiri::XML::DocumentFragment.new(fragment.document)
        remaining = text_node.content

        while (match = Icons::SHORTCODE_PATTERN.match(remaining))
          replacement.add_child(Nokogiri::XML::Text.new(remaining[0...match.begin(0)], fragment.document)) if match.begin(0).positive?
          replacement.add_child(icon_node(fragment, match[:name]))
          remaining = remaining[match.end(0)..]
        end

        replacement.add_child(Nokogiri::XML::Text.new(remaining, fragment.document)) if remaining.present?
        text_node.replace(replacement)
      end
    end

    def icon_node(fragment, name)
      case (icon = Icons.find(name))
      when Icons::Brand
        if (url = Icons.brand_image_urls[icon.name])
          Nokogiri::XML::Node.new("img", fragment.document).tap do |img|
            img["class"] = "icon icon--brand"
            img["src"] = url
            img["alt"] = ":#{icon.name}:"
            img["title"] = icon.title
            img["draggable"] = "false"
          end
        else
          # The asset is missing (see Icons.brand_image_urls); leave the
          # shortcode literal rather than emitting a broken image.
          Nokogiri::XML::Text.new(":#{name}:", fragment.document)
        end
      when Icons::Emoji
        Nokogiri::XML::Text.new(icon.character, fragment.document)
      else
        Nokogiri::XML::Text.new(":#{name}:", fragment.document)
      end
    end

    def skipped_icon_context?(text_node)
      text_node.ancestors.any? { |ancestor| SKIPPED_ICON_ANCESTORS.include?(ancestor.name) }
    end
end
