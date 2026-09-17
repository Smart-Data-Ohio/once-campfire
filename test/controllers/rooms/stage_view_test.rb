require "test_helper"

class Rooms::StageViewTest < ActionDispatch::IntegrationTest
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"

    @room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:kevin) ])
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "a listener's join control hints that publishing is unavailable" do
    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/data-huddle-can-publish-param="false"/, response.body)
  end

  test "a host's join control hints that publishing is available" do
    sign_in :david
    get room_url(@room)

    assert_response :success
    assert_match(/data-huddle-can-publish-param="true"/, response.body)
  end

  test "a speaker's join control hints that publishing is available" do
    @room.memberships.find_by!(user: users(:kevin)).change_stage_role!("speaker")

    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/data-huddle-can-publish-param="true"/, response.body)
  end

  test "a voice channel's join control carries no publishing hint" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:kevin) ])

    sign_in :kevin
    get room_url(voice)

    assert_response :success
    assert_match(/Join voice/, response.body)
    assert_no_match(/data-huddle-can-publish-param/, response.body)
  end

  test "the layout renders the persistent role-event target for signed-in users" do
    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/id="huddle_role_events"/, response.body)
  end

  test "a listener's stage panel renders no role forms" do
    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/You are in the audience/, response.body)
    assert_no_match(/Invite to speak/, response.body)
    assert_no_match(/Make host/, response.body)
    assert_no_match(/Move to audience/, response.body)
    assert_no_match(/Move to speakers/, response.body)
  end

  test "a host's stage panel renders role forms" do
    sign_in :david
    get room_url(@room)

    assert_response :success
    assert_match(/Invite to speak/, response.body)
    assert_match(/Make host/, response.body)
  end

  test "the header Live badge renders only while live" do
    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_no_match(/Live: David/, response.body)

    grant = HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"),
      membership: @room.memberships.find_by!(user: users(:david)))
    Stream.create!(room: @room, membership: @room.memberships.find_by!(user: users(:david)),
      user: users(:david), quality: "1080p15")
    get room_url(@room)

    assert_response :success
    assert_match(/Live: David/, response.body)
    assert_match(/data-presenter-id="#{grant.identity}"/, response.body)
  end

  test "the sidebar live dot renders only while live" do
    sign_in :kevin
    get user_sidebar_url

    assert_response :success
    assert_no_match(/stage-live-dot__pip/, response.body)

    Stream.create!(room: @room, membership: @room.memberships.find_by!(user: users(:david)),
      user: users(:david), quality: "1080p15")
    get user_sidebar_url

    assert_response :success
    assert_match(/stage-live-dot__pip/, response.body)
  end

  test "the Go live form renders for hosts and speakers" do
    sign_in :david
    get room_url(@room)

    assert_response :success
    assert_match(/Stream quality/, response.body)
    assert_match(/Go live/, response.body)

    @room.memberships.find_by!(user: users(:kevin)).change_stage_role!("speaker")

    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/Stream quality/, response.body)
    assert_match(/Go live/, response.body)
  end

  test "the Go live form renders for no listener and never while live" do
    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_no_match(/Go live/, response.body)

    Stream.create!(room: @room, membership: @room.memberships.find_by!(user: users(:david)),
      user: users(:david), quality: "1080p15")

    sign_in :david
    get room_url(@room)

    assert_response :success
    assert_no_match(/Go live/, response.body)
    assert_match(/Live: David/, response.body)
  end

  test "Stop stream renders for the presenter but not for listeners" do
    Stream.create!(room: @room, membership: @room.memberships.find_by!(user: users(:david)),
      user: users(:david), quality: "1080p15")

    sign_in :david
    get room_url(@room)

    assert_response :success
    assert_match(/Stop stream/, response.body)

    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/Live: David/, response.body)
    assert_no_match(/Stop stream/, response.body)
  end

  test "Stop stream renders for hosts and the presenting speaker" do
    speaker = @room.memberships.find_by!(user: users(:kevin))
    speaker.change_stage_role!("speaker")
    Stream.create!(room: @room, membership: speaker, user: users(:kevin), quality: "1080p15")

    sign_in :kevin
    get room_url(@room)

    assert_response :success
    assert_match(/Stop stream/, response.body)

    sign_in :david
    get room_url(@room)

    assert_response :success
    assert_match(/Stop stream/, response.body)
  end
end
