class ContentFilters::RemoveSoloUnfurledLinkText < ActionText::Content::Filter
  def applicable?
    normalize_tweet_url(solo_unfurled_url) == normalize_tweet_url(content.to_plain_text)
  end

  def apply
    fragment.replace("div") do |node|
      node.tap { |div| strip_link_text(div) unless inside_attachment?(div) }
    end
  end

  private
    TWITTER_DOMAINS = %w[ x.com twitter.com ]
    TWITTER_DOMAIN_MAPPING = { "x.com" => "twitter.com" }

    # Drop the redundant link text but leave the attachment where it is:
    # legacy bodies keep it as a sibling of the text div, so rewriting the
    # div to a copy of the attachment would render the box twice.
    def strip_link_text(div)
      div.children.each { |child| child.remove unless attachment_node?(child) }
    end

    def attachment_node?(node)
      node.element? && node.name == ActionText::Attachment.tag_name
    end

    def inside_attachment?(node)
      node.ancestors(ActionText::Attachment.tag_name).any?
    end

    def solo_unfurled_url
      unfurled_links.first["href"] if unfurled_links.size == 1
    end

    def unfurled_links
      fragment.find_all("action-text-attachment[@content-type='#{ActionText::Attachment::OpengraphEmbed::OPENGRAPH_EMBED_CONTENT_TYPE}']")
    end

    def normalize_tweet_url(url)
      return url unless twitter_url?(url)

      uri = URI.parse(url)

      uri.dup.tap do |u|
        u.host = TWITTER_DOMAIN_MAPPING[uri.host&.downcase] || uri.host
        u.query = nil
      end.to_s
    rescue URI::InvalidURIError
      url
    end

    def twitter_url?(url)
      url.present? && TWITTER_DOMAINS.any? { |domain| url.strip.include?(domain) }
    end
end
