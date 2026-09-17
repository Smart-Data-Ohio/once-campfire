module BoostsHelper
  # Brand shortcode boosts render the icon; everything else renders as plain
  # text exactly like before.
  def boost_content_html(boost)
    if boost.shortcode_content?
      icon = Icons.find(boost.content.to_s[1...-1])

      # Resolved through the registry so a brand whose asset is missing
      # falls back to its literal text instead of raising at render time.
      if icon.is_a?(Icons::Brand) && (url = Icons.brand_image_urls[icon.name])
        return image_tag(url,
          class: "icon icon--brand", alt: ":#{icon.name}:", title: icon.title, draggable: "false")
      end
    end

    h(boost.content)
  end
end
