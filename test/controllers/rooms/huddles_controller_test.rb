require "test_helper"

class Rooms::HuddlesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
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

  test "an authorized room member receives a narrowly scoped join token" do
    sign_in :david

    post room_huddle_url(rooms(:watercooler)), params: { room: "client-room", identity: "client-identity" }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]

    body = response.parsed_body
    claims, headers = JWT.decode(body.fetch("token"), "test-api-secret", true, algorithm: "HS256")

    assert_equal "wss://huddle.example.test", body.fetch("url")
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
    assert_equal %w[ microphone screen_share screen_share_audio camera ], grant.fetch("canPublishSources")
    assert_equal false, grant.fetch("roomCreate")
    assert_equal false, grant.fetch("roomList")
    assert_equal false, grant.fetch("roomAdmin")
    assert_equal false, grant.fetch("roomRecord")
    assert_not_equal "client-room", grant.fetch("room")
    assert_not_equal "client-identity", claims.fetch("sub")

    persisted_grant = HuddleGrant.find(body.fetch("grant_id"))
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    assert_equal current_session.id, persisted_grant.session_id
    assert_equal users(:david).id, persisted_grant.user_id
    assert_equal memberships(:david_watercooler).id, persisted_grant.membership_id
    assert_equal rooms(:watercooler).id, persisted_grant.room_id
  end

  test "the active grant is reused while its random participant identity remains opaque" do
    membership = memberships(:david_watercooler)
    first = Huddle.new(room: membership.room, user: membership.user, session: sessions(:david_safari), membership: membership)
    second = Huddle.new(room: membership.room, user: membership.user, session: sessions(:david_safari), membership: membership)

    assert_equal first.room_name, second.room_name
    assert_equal first.identity, second.identity
    assert_equal first.grant_id, second.grant_id
    assert_not_equal first.room_name.delete_prefix("campfire-room-"), first.identity.delete_prefix("campfire-participant-")
  end

  test "direct rooms use their participant-based display name" do
    sign_in :david

    get room_huddle_url(rooms(:david_and_jason))

    assert_response :success
    assert_equal "Jason", response.parsed_body.dig("room", "name")
  end

  test "starting a one-to-one DM huddle invites only the other participant" do
    sign_in :david

    assert_enqueued_with(job: Huddle::PushInvitationJob) do
      post room_huddle_url(rooms(:david_and_jason))
    end

    assert_response :success
    item = ActivityItem.find_by!(user: users(:jason), event_type: "huddle_started")
    assert_equal response.parsed_body.fetch("grant_id"), item.source_id
    assert_equal "huddle_started", item.event_type
    assert_not ActivityItem.exists?(user: users(:david), event_type: "huddle_started")
  end

  test "starting a channel huddle creates no invitation" do
    sign_in :david

    assert_no_difference -> { ActivityItem.count } do
      post room_huddle_url(rooms(:watercooler))
    end

    assert_response :success
  end

  test "group direct rooms cannot start a huddle" do
    room = Rooms::Direct.create_for({ creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    sign_in :david

    post room_huddle_url(room)

    assert_json_error :unprocessable_entity, "Huddles are only available in one-to-one direct messages"
    assert_not HuddleGrant.exists?(room_id: room.id)
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

  test "participants lists the room's in-call members without caching" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    david_grant.update_columns(last_seen_at: Time.current)
    jason_grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: room.memberships.find_by!(user: users(:jason)))
    jason_grant.update_columns(last_seen_at: Time.current)

    sign_in :david
    get participants_room_huddle_url(room)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal [
      { "id" => users(:david).id, "name" => users(:david).name, "avatar_url" => fresh_user_avatar_url(users(:david)) },
      { "id" => users(:jason).id, "name" => users(:jason).name, "avatar_url" => fresh_user_avatar_url(users(:jason)) }
    ], response.parsed_body
  end

  test "participants reflects only in-call grants" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    david_grant.update_columns(last_seen_at: Time.current)
    # Issued but never seen by the gateway.
    HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: room.memberships.find_by!(user: users(:jason)))
    # Seen, but outside the in-call window.
    kevin_grant = HuddleGrant.issue!(session: users(:kevin).sessions.create!(user_agent: "Test"), membership: room.memberships.find_by!(user: users(:kevin)))
    kevin_grant.update_columns(last_seen_at: 21.seconds.ago)

    sign_in :david
    get participants_room_huddle_url(room)

    assert_response :success
    assert_equal [ users(:david).id ], response.parsed_body.pluck("id")
  end

  test "a member removed mid-call is revoked and disappears from participants" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    grant.update_columns(last_seen_at: Time.current)

    sign_in :jason
    get participants_room_huddle_url(room)
    assert_equal [ users(:david).id ], response.parsed_body.pluck("id")

    room.memberships.find_by!(user: users(:david)).destroy!
    assert grant.reload.revoked?

    get participants_room_huddle_url(room)
    assert_response :success
    assert_empty response.parsed_body
  end

  test "participants is reported for group direct rooms" do
    room = Rooms::Direct.create_for({ creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    grant.update_columns(last_seen_at: Time.current)

    sign_in :david
    get participants_room_huddle_url(room)

    assert_response :success
    assert_equal [ users(:david).id ], response.parsed_body.pluck("id")
  end

  test "participants denies non-members, outsiders, and unauthenticated requests" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    sign_in :jz
    get participants_room_huddle_url(room)
    assert_json_error :not_found, "Room not found or inaccessible"

    sign_in :jz
    get participants_room_huddle_url(rooms(:david_and_jason))
    assert_json_error :not_found, "Room not found or inaccessible"

    delete session_url
    get participants_room_huddle_url(room)
    assert_json_error :unauthorized, "Authentication required"
  end

  test "participants denies bots and inactive users" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    get participants_room_huddle_url(room), params: { bot_key: users(:bender).bot_key }
    assert_json_error :forbidden, "Bots cannot join huddles"

    bot = users(:bender)
    bot.update!(email_address: "bender@example.test", password: "secret123456")
    sign_in bot
    get participants_room_huddle_url(room)
    assert_json_error :forbidden, "Bots cannot join huddles"

    sign_in :david
    users(:david).banned!
    get participants_room_huddle_url(room)
    assert_json_error :forbidden, "User cannot join huddles"
  end

  test "participants requires LiveKit configuration" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])

    sign_in :david
    ENV.delete("LIVEKIT_API_SECRET")
    get participants_room_huddle_url(room)

    assert_json_error :service_unavailable, "Huddles are not configured"
  end

  test "GET denies access after sign out" do
    sign_in :david
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    membership = memberships(:david_watercooler)
    grant = HuddleGrant.issue!(session: current_session, membership: membership)
    post room_huddle_url(rooms(:watercooler))
    assert_response :success

    delete session_url
    get room_huddle_url(rooms(:watercooler))

    assert_json_error :unauthorized, "Authentication required"
    assert grant.reload.revoked?
    assert HuddleCleanup.exists?(operation: :remove_participant, huddle_grant_id: grant.id)
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

  test "a concurrent membership revocation receives a controlled denial" do
    sign_in :david
    HuddleGrant.stubs(:issue!).raises(HuddleGrant::Ineligible)

    post room_huddle_url(rooms(:watercooler))

    assert_json_error :not_found, "Room not found or inaccessible"
  end

  test "a public URL pointing directly at the internal LiveKit address is rejected" do
    sign_in :david
    ENV["LIVEKIT_URL"] = "wss://livekit.example.test:7880/client/path"

    post room_huddle_url(rooms(:watercooler))

    assert_json_error :service_unavailable, "Huddles are not configured"
    assert_empty HuddleGrant.all
  end

  private
    def assert_json_error(status, message)
      assert_response status
      assert_equal({ "error" => message }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]
    end
end
