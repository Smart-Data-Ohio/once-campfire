require "test_helper"

class Rooms::HuddlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_livekit_environment = ENV.values_at("LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_URL"] = "wss://livekit.example.test"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
  end

  teardown do
    %w[ LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET ].zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "an authorized room member receives a narrowly scoped join token" do
    sign_in :david

    post room_huddle_url(rooms(:watercooler)), params: { room: "client-room", identity: "client-identity" }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]

    body = response.parsed_body
    claims, headers = JWT.decode(body.fetch("token"), "test-api-secret", true, algorithm: "HS256")

    assert_equal "wss://livekit.example.test", body.fetch("url")
    assert_equal({ "id" => rooms(:watercooler).id, "name" => rooms(:watercooler).name }, body.fetch("room"))
    assert_equal claims.fetch("sub"), body.fetch("identity")
    assert_match(/\Acampfire-participant-[0-9a-f]{64}\z/, body.fetch("identity"))
    assert_match(/\Acampfire-room-[0-9a-f]{64}\z/, claims.dig("video", "room"))
    assert_equal "HS256", headers.fetch("alg")
    assert_equal "test-api-key", claims.fetch("iss")
    assert_equal users(:david).name, claims.fetch("name")
    assert_operator claims.fetch("exp") - claims.fetch("iat"), :<=, 2.minutes.to_i
    assert_operator claims.fetch("exp"), :>, Time.current.to_i

    grant = claims.fetch("video")
    assert_equal true, grant.fetch("roomJoin")
    assert_equal true, grant.fetch("canPublish")
    assert_equal true, grant.fetch("canSubscribe")
    assert_equal false, grant.fetch("canPublishData")
    assert_equal %w[ microphone screen_share screen_share_audio ], grant.fetch("canPublishSources")
    assert_equal false, grant.fetch("roomCreate")
    assert_equal false, grant.fetch("roomList")
    assert_equal false, grant.fetch("roomAdmin")
    assert_equal false, grant.fetch("roomRecord")
    assert_not_equal "client-room", grant.fetch("room")
    assert_not_equal "client-identity", claims.fetch("sub")
  end

  test "room and participant identifiers are stable and scoped by record type" do
    first = Huddle.new(room: rooms(:watercooler), user: users(:david), session: sessions(:david_safari))
    second = Huddle.new(room: rooms(:watercooler), user: users(:david), session: sessions(:david_safari))

    assert_equal first.room_name, second.room_name
    assert_equal first.identity, second.identity
    assert_not_equal first.room_name.delete_prefix("campfire-room-"), first.identity.delete_prefix("campfire-participant-")
  end

  test "direct rooms use their participant-based display name" do
    sign_in :david

    get room_huddle_url(rooms(:david_and_jason))

    assert_response :success
    assert_equal "Jason", response.parsed_body.dig("room", "name")
  end

  test "GET confirms ongoing access without returning credentials" do
    sign_in :david

    get room_huddle_url(rooms(:watercooler))

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "room" => { "id" => rooms(:watercooler).id, "name" => rooms(:watercooler).name } }, response.parsed_body)
    assert_not response.parsed_body.key?("token")
    assert_not response.parsed_body.key?("url")
    assert_not response.parsed_body.key?("identity")
  end

  test "GET denies access after room membership is revoked" do
    sign_in :david
    get room_huddle_url(rooms(:watercooler))
    assert_response :success

    memberships(:david_watercooler).destroy!
    get room_huddle_url(rooms(:watercooler))

    assert_json_error :not_found, "Room not found or inaccessible"
  end

  test "GET denies access after sign out" do
    sign_in :david
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    other_session = sessions(:david_safari)
    expected_room_names = users(:david).room_ids.map { |room_id| Huddle.room_name(room_id) }
    get room_huddle_url(rooms(:watercooler))
    assert_response :success

    assert_enqueued_jobs expected_room_names.size, only: Huddle::RevokeParticipantJob do
      delete session_url
    end
    get room_huddle_url(rooms(:watercooler))

    assert_json_error :unauthorized, "Authentication required"
    args = enqueued_jobs.filter_map { |job| job[:args] if job[:job] == Huddle::RevokeParticipantJob }
    assert_equal expected_room_names.sort, args.map(&:first).sort
    assert args.all? { |_, identity| identity == Huddle.identity(current_session.id) }
    assert_not_includes args.flatten, Huddle.identity(other_session.id)
  end

  test "a nonmember cannot join a closed room" do
    sign_in :kevin

    post room_huddle_url(rooms(:watercooler))

    assert_json_error :not_found, "Room not found or inaccessible"
  end

  test "an outsider cannot join a direct room" do
    sign_in :jz

    post room_huddle_url(rooms(:david_and_jason))

    assert_json_error :not_found, "Room not found or inaccessible"
  end

  test "an unauthenticated request receives JSON instead of a redirect" do
    post room_huddle_url(rooms(:watercooler))

    assert_json_error :unauthorized, "Authentication required"
    assert_not response.redirect?
  end

  test "bots cannot join" do
    post room_huddle_url(rooms(:watercooler)), params: { bot_key: users(:bender).bot_key }

    assert_json_error :forbidden, "Bots cannot join huddles"
  end

  test "bots cannot join through an ordinary session" do
    bot = users(:bender)
    bot.update!(email_address: "bender@example.test", password: "secret123456")
    sign_in bot

    post room_huddle_url(rooms(:watercooler))

    assert_json_error :forbidden, "Bots cannot join huddles"
  end

  test "banned users cannot join" do
    sign_in :david
    users(:david).banned!

    post room_huddle_url(rooms(:watercooler))

    assert_json_error :forbidden, "User cannot join huddles"
  end

  test "missing LiveKit configuration is reported without minting a token" do
    sign_in :david
    ENV.delete("LIVEKIT_API_SECRET")

    post room_huddle_url(rooms(:watercooler))

    assert_json_error :service_unavailable, "Huddles are not configured"
    assert_not response.parsed_body.key?("token")
  end

  private
    def assert_json_error(status, message)
      assert_response status
      assert_equal({ "error" => message }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]
    end
end
