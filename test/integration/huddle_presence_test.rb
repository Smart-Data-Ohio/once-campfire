require "test_helper"

class HuddlePresenceTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david

    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "channel header shows the live stack immediately before the join button" do
    room = rooms(:watercooler)
    issue_in_call_grant!(user: users(:jason), room: room)

    get room_url(room)

    assert_response :success
    assert_select ".room-header__actions .voice-stack--live.voice-stack--huddle" +
      "[aria-label='1 in huddle: Jason'][title='1 in huddle: Jason']" +
      "[data-huddle-participants-interval-value='15000'][data-huddle-participants-label-value='in huddle']" do
      assert_select ".voice-stack__count", text: "1"
      assert_select "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']"
    end
    assert_select ".room-header__actions .voice-stack--live + button.huddle-launcher", text: "Join huddle"
  end

  test "quiet channel header keeps an empty stack target" do
    get room_url(rooms(:watercooler))

    assert_response :success
    assert_select ".room-header__actions .voice-stack:not(.voice-stack--live)[aria-label='Nobody in huddle']" do
      assert_select ".voice-stack__avatar", count: 0
      assert_select ".voice-stack__count[hidden]", visible: false
    end
    assert_select ".room-header__actions button.huddle-launcher", text: "Join huddle"
  end

  test "two-person DM header shows the live stack" do
    room = rooms(:david_and_jason)
    issue_in_call_grant!(user: users(:jason), room: room)

    get room_url(room)

    assert_response :success
    assert_select ".room-header__actions .voice-stack--live[aria-label='1 in huddle: Jason']" do
      assert_select ".voice-stack__count", text: "1"
    end
  end

  test "group DM header shows neither a stack nor a launcher" do
    group = Rooms::Direct.create_for({ creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    issue_in_call_grant!(user: users(:jason), room: group)

    get room_url(group)

    assert_response :success
    assert_select ".room-header__actions .voice-stack", count: 0
    assert_select ".room-header__actions button.huddle-launcher", count: 0
  end

  test "no header stack without huddle configuration" do
    ENV.delete("LIVEKIT_GATEWAY_SECRET")
    issue_in_call_grant!(user: users(:jason), room: rooms(:watercooler))

    get room_url(rooms(:watercooler))

    assert_response :success
    assert_select ".room-header__actions .voice-stack", count: 0
  end

  private
    def issue_in_call_grant!(user:, room:)
      session = user.sessions.find_by(user_agent: "Test") || user.sessions.create!(user_agent: "Test")
      HuddleGrant.issue!(session: session, membership: room.memberships.find_by!(user: user)).tap do |grant|
        grant.update_columns(last_seen_at: Time.current)
      end
    end
end
