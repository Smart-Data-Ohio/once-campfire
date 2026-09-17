require "test_helper"

class BoostTest < ActiveSupport::TestCase
  test "accepts a brand shortcode" do
    boost = Boost.new(message: messages(:first), booster: users(:david), content: ":openai:")

    assert boost.valid?
  end

  test "stores an emoji shortcode as its character" do
    boost = Boost.create!(message: messages(:first), booster: users(:david), content: ":thumbsup:")

    assert_equal "👍", boost.reload.content
    assert_not boost.shortcode_content?
  end

  test "rejects an unknown shortcode" do
    boost = Boost.new(message: messages(:first), booster: users(:david), content: ":nope_not_real:")

    assert_not boost.valid?
    assert_includes boost.errors[:content], "is not a known brand icon"
  end

  test "leaves existing plain-text and emoji content unchanged" do
    assert Boost.new(message: messages(:first), booster: users(:david), content: "Morning!").valid?
    assert Boost.new(message: messages(:first), booster: users(:david), content: "💯").valid?
    assert Boost.new(message: messages(:first), booster: users(:david), content: "great :fire: work").valid?
  end
end
