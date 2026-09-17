require "test_helper"

class IconsAvatarHelperTest < ActionView::TestCase
  tests IconsAvatarHelper

  test "brand icon renders an img from the existing asset path with the title as alt" do
    img = fragment_for(icon_avatar_tag("openai", size: 32)).at_css("img")

    assert_equal Icons.brand_image_urls.fetch("openai"), img["src"]
    assert_equal "OpenAI", img["alt"]
    assert_equal "32", img["width"]
    assert_equal "32", img["height"]
    assert_includes img["class"].split, "icon-avatar"
    assert_includes img["class"].split, "icon-avatar--brand"
  end

  test "workspace icon renders an img from the stable icon route" do
    create_workspace_icon(name: "acme", title: "Acme")

    img = fragment_for(icon_avatar_tag("acme", size: 24)).at_css("img")

    assert_equal "/icons/acme", img["src"]
    assert_equal "Acme", img["alt"]
    assert_equal "24", img["width"]
    assert_includes img["class"].split, "icon-avatar--custom"
  end

  test "emoji renders a span glyph with an accessible name" do
    span = fragment_for(icon_avatar_tag("thumbsup", size: 24)).at_css("span")

    assert_equal "👍", span.text
    assert_equal "img", span["role"]
    assert_equal "Thumbsup", span["aria-label"]
    assert_includes span["style"], "font-size: 24px"
    assert_includes span["class"].split, "icon-avatar--emoji"
  end

  test "colon-wrapped shortcodes resolve like bare names" do
    img = fragment_for(icon_avatar_tag(":openai:", size: 24)).at_css("img")

    assert_equal Icons.brand_image_urls.fetch("openai"), img["src"]
  end

  test "caller classes are appended to the avatar classes" do
    img = fragment_for(icon_avatar_tag("openai", size: 32, class: "room-header__icon")).at_css("img")

    assert_includes img["class"].split, "icon-avatar"
    assert_includes img["class"].split, "room-header__icon"
  end

  test "unknown, blank, and missing names return nil so callers fall back" do
    assert_nil icon_avatar_tag("nope_not_real", size: 24)
    assert_nil icon_avatar_tag("", size: 24)
    assert_nil icon_avatar_tag(nil, size: 24)
  end

  test "a deleted workspace icon resolves to nil without raising" do
    create_workspace_icon(name: "acme").destroy

    assert_nil icon_avatar_tag("acme", size: 24)
  end

  test "titles are HTML-escaped" do
    create_workspace_icon(name: "acme", title: %q{Acme"><script>alert(1)</script>})

    html = icon_avatar_tag("acme", size: 24).to_s

    assert_no_match(/<script/, html)
    assert_includes html, "Acme&quot;&gt;&lt;script&gt;"
  end

  test "icon_avatar_url resolves image paths and nil for emoji and unknown names" do
    create_workspace_icon(name: "acme")

    assert_equal Icons.brand_image_urls.fetch("openai"), icon_avatar_url("openai")
    assert_equal "/icons/acme", icon_avatar_url("acme")
    assert_equal Icons.brand_image_urls.fetch("openai"), icon_avatar_url(":openai:")
    assert_nil icon_avatar_url("thumbsup")
    assert_nil icon_avatar_url("nope_not_real")
    assert_nil icon_avatar_url(nil)
  end

  private
    def fragment_for(tag)
      Nokogiri::HTML5.fragment(tag.to_s)
    end
end
