require "test_helper"

class Messages::BoostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @message = messages(:first)
  end

  test "create" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      assert_difference -> { @message.boosts.count }, 1 do
        post message_boosts_url(@message, format: :turbo_stream), params: { boost: { content: "Morning!" } }
        assert_redirected_to message_boosts_url(@message)
      end
    end
  end

  test "destroy" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      assert_difference -> { @message.boosts.count }, -1 do
        delete message_boost_url(@message, boosts(:first), format: :turbo_stream)
        assert_response :success
      end
    end
  end

  test "a human emoji toggle removes legacy duplicates under the message lock" do
    emoji = "👍"
    Boost.create!(message: @message, booster: users(:david), content: emoji)
    Boost.create!(message: @message, booster: users(:david), content: emoji)

    assert_difference -> { @message.boosts.where(booster: users(:david), content: emoji).count }, -2 do
      post message_boosts_url(@message, format: :turbo_stream), params: { boost: { content: emoji } }
      assert_redirected_to message_boosts_url(@message)
    end
  end

  test "create accepts a brand shortcode and renders its icon" do
    assert_difference -> { @message.boosts.count }, 1 do
      post message_boosts_url(@message, format: :turbo_stream), params: { boost: { content: ":openai:" } }
      assert_redirected_to message_boosts_url(@message)
    end

    get message_boosts_url(@message)

    assert_response :success
    icon = Nokogiri::HTML5.fragment(response.body).at_css("img.icon--brand")
    assert icon, "expected an icon image in #{response.body}"
    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z}, icon["src"]
    assert_equal ":openai:", icon["alt"]
  end

  test "create stores an unknown shortcode as literal text" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      assert_difference -> { @message.boosts.count }, 1 do
        post message_boosts_url(@message, format: :turbo_stream), params: { boost: { content: ":lol:" } }
        assert_redirected_to message_boosts_url(@message)
      end
    end

    assert_equal ":lol:", @message.boosts.last.content

    get message_boosts_url(@message)

    assert_response :success
    assert_includes response.body, ":lol:"
    assert_empty Nokogiri::HTML5.fragment(response.body).css("img.icon--brand")
  end

  test "action metadata groups reaction counts by distinct reactor" do
    emoji = "👍"
    Boost.create!(message: @message, booster: users(:david), content: emoji)
    Boost.create!(message: @message, booster: users(:david), content: emoji)
    Boost.create!(message: @message, booster: users(:jason), content: emoji)

    get actions_room_message_url(@message.room, @message, format: :json)

    assert_response :success
    reaction = response.parsed_body.dig("actions", "reactions", emoji)
    assert_equal 2, reaction.fetch("count")
    assert reaction.fetch("active")
  end
end
