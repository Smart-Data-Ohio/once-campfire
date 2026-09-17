module IconsAvatarHelper
  # Renders any resolvable icon at avatar sizes: brand and workspace icons as
  # an <img> from their existing paths with alt set to the icon title, emoji
  # as a <span> glyph with an accessible name. Returns nil for a blank or
  # unresolvable name so callers fall back to their default marker.
  def icon_avatar_tag(icon_name, size:, **options)
    icon = resolved_avatar_icon(icon_name)
    return if icon.nil?

    if icon.emoji?
      emoji_avatar_tag(icon, size:, **options)
    elsif (url = Icons.image_url_for(icon))
      image_avatar_tag(icon, url, size:, **options)
    end
  end

  # Same-origin image path for a brand or workspace icon, for JSON clients.
  # Emoji, unknown names, and blank input resolve to nil.
  def icon_avatar_url(icon_name)
    icon = resolved_avatar_icon(icon_name)
    Icons.image_url_for(icon) if icon && !icon.emoji?
  end

  private
    def resolved_avatar_icon(icon_name)
      normalized = Icons.normalize_name(icon_name)
      normalized ? Icons.find(normalized) : nil
    end

    def image_avatar_tag(icon, url, size:, **options)
      options[:class] = [ "icon-avatar", icon.brand? ? "icon-avatar--brand" : "icon-avatar--custom", options[:class] ].compact_blank.join(" ")
      image_tag url, **{ alt: icon.title, size: size }.merge(options)
    end

    def emoji_avatar_tag(icon, size:, **options)
      options[:class] = [ "icon-avatar", "icon-avatar--emoji", options[:class] ].compact_blank.join(" ")
      options[:style] = [ "font-size: #{size.to_i}px", options[:style] ].compact_blank.join("; ")
      tag.span icon.character, **{ role: "img", aria: { label: icon.title } }.merge(options)
    end
end
