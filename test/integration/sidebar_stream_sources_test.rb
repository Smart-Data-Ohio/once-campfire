require "test_helper"

class SidebarStreamSourcesTest < ActionDispatch::IntegrationTest
  test "the signed-in layout subscribes to the rooms streams outside the sidebar frame" do
    sign_in :david

    get room_url(rooms(:hq))
    assert_response :success

    assert_select "turbo-cable-stream-source[signed-stream-name='#{rooms_stream_name}']", count: 1
    assert_select "turbo-cable-stream-source[signed-stream-name='#{user_rooms_stream_name(users(:david))}']", count: 1
    assert_select "turbo-frame#user_sidebar turbo-cable-stream-source", count: 0
    assert_select "#sidebar turbo-cable-stream-source", count: 0
  end

  test "the sidebar frame renders no stream sources" do
    sign_in :david

    get user_sidebar_url
    assert_response :success
    assert_select "turbo-frame#user_sidebar"
    assert_select "turbo-frame#user_sidebar turbo-cable-stream-source", count: 0
  end

  test "signed-out pages render no stream sources" do
    get new_session_url
    assert_response :success
    assert_select "turbo-cable-stream-source", count: 0
  end

  private
    def rooms_stream_name
      Turbo::StreamsChannel.signed_stream_name([ :rooms ])
    end

    def user_rooms_stream_name(user)
      Turbo::StreamsChannel.signed_stream_name([ user, :rooms ])
    end
end
