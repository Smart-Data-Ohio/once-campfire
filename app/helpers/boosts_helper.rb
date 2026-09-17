module BoostsHelper
  # Brand shortcode boosts render the icon; everything else renders as plain
  # text exactly like before.
  def boost_content_html(boost)
    if boost.shortcode_content?
      icon = Icons.find(boost.content.to_s[1...-1])

      if icon.is_a?(Icons::Brand)
        return image_tag(icon.logical_asset_path,
          class: "icon icon--brand", alt: ":#{icon.name}:", title: icon.title, draggable: "false")
      end
    end

    h(boost.content)
  end
end
