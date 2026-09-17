module BoostsHelper
  # Brand and workspace icon shortcode boosts render the icon; everything
  # else renders as plain text exactly like before.
  def boost_content_html(boost)
    if boost.shortcode_content?
      icon = Icons.find(boost.content.to_s[1...-1])

      # Resolved through the registry so an icon whose asset is missing
      # falls back to its literal text instead of raising at render time.
      if icon && (url = Icons.image_url_for(icon))
        return image_tag(url,
          class: icon_css_class(icon), alt: ":#{icon.name}:", title: icon.title, draggable: "false")
      end
    end

    h(boost.content)
  end

  private
    # Icons.image_url_for only resolves brands and workspace icons, so
    # anything reaching here is one of the two.
    def icon_css_class(icon)
      icon.brand? ? "icon icon--brand" : "icon icon--custom"
    end
end
