require "test_helper"

class Users::AvatarsHelperTest < ActionView::TestCase
  tests Users::AvatarsHelper

  test "emoji bot icons keep their accessible name and ignore img-only options" do
    users(:bender).update!(icon_name: "thumbsup")

    span = fragment_for(avatar_image_tag(users(:bender), size: 48, loading: :lazy, aria: { hidden: "true" })).at_css("span")

    assert_equal "👍", span.text
    assert_equal "Thumbsup", span["aria-label"]
    assert_nil span["loading"]
  end

  test "bot icon images keep caller classes" do
    users(:bender).update!(icon_name: "openai")

    img = fragment_for(avatar_image_tag(users(:bender), size: 48, class: "message__avatar-img")).at_css("img")

    assert_includes img["class"].split, "icon-avatar"
    assert_includes img["class"].split, "message__avatar-img"
  end

  private
    def fragment_for(tag)
      Nokogiri::HTML5.fragment(tag.to_s)
    end
end
