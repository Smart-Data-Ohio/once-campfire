require "test_helper"

class Users::HuddlePresenceControllerTest < ActionDispatch::IntegrationTest
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

  test "returns only the current user's rooms with at least one participant" do
    channel = rooms(:hq)
    issue_in_call_grant!(user: users(:david), room: channel)
    issue_in_call_grant!(user: users(:jason), room: channel)
    # A second session for the same user still counts as one participant.
    issue_in_call_grant!(user: users(:david), room: channel, session: users(:david).sessions.create!(user_agent: "Other"))
    # Seen, but outside the in-call window.
    expired = issue_in_call_grant!(user: users(:kevin), room: channel)
    expired.update_columns(last_seen_at: 21.seconds.ago)
    # In the call, then revoked.
    revoked = issue_in_call_grant!(user: users(:jz), room: channel)
    revoked.revoke!

    direct = rooms(:david_and_jason)
    issue_in_call_grant!(user: users(:jason), room: direct)

    # Issued but never seen by the gateway: the room stays out.
    HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    # A room the current user cannot see stays out.
    strangers = Rooms::Closed.create_for({ name: "Secret", creator: users(:jason) }, users: [ users(:jason), users(:kevin) ])
    issue_in_call_grant!(user: users(:jason), room: strangers)

    sign_in :david
    get huddle_presence_users_url

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal [
      {
        "room_id" => channel.id,
        "participants" => [
          { "id" => users(:david).id, "name" => users(:david).name, "avatar_url" => fresh_user_avatar_url(users(:david)) },
          { "id" => users(:jason).id, "name" => users(:jason).name, "avatar_url" => fresh_user_avatar_url(users(:jason)) }
        ]
      },
      {
        "room_id" => direct.id,
        "participants" => [
          { "id" => users(:jason).id, "name" => users(:jason).name, "avatar_url" => fresh_user_avatar_url(users(:jason)) }
        ]
      }
    ], response.parsed_body.sort_by { |room| room["room_id"] == channel.id ? 0 : 1 }
  end

  test "the response runs one grants query no matter how many rooms are live" do
    issue_in_call_grant!(user: users(:david), room: rooms(:hq))
    issue_in_call_grant!(user: users(:jason), room: rooms(:hq))
    issue_in_call_grant!(user: users(:david), room: rooms(:watercooler))
    issue_in_call_grant!(user: users(:jason), room: rooms(:david_and_jason))

    sign_in :david
    queries = capture_select_sql { get huddle_presence_users_url }

    assert_response :success
    assert_equal 3, response.parsed_body.count
    assert_equal 1, queries.count { |sql| sql.include?("FROM \"huddle_grants\"") },
      "expected one grants query, saw: #{queries.grep(/huddle_grants/).inspect}"
    assert_equal 1, queries.count { |sql| sql.include?("FROM \"users\" WHERE \"users\".\"id\" IN (") },
      "expected one users preload query, saw: #{queries.grep(/FROM \"users\"/).inspect}"
  end

  test "returns an empty list when nobody is in any call" do
    HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_hq))

    sign_in :david
    get huddle_presence_users_url

    assert_response :success
    assert_equal [], response.parsed_body
  end

  test "an unauthenticated request receives JSON instead of a redirect" do
    get huddle_presence_users_url

    assert_json_error :unauthorized, "Authentication required"
    assert_not response.redirect?
  end

  test "bots and inactive users are denied like the huddle controller" do
    get huddle_presence_users_url, params: { bot_key: users(:bender).bot_key }
    assert_json_error :forbidden, "Bots cannot join huddles"

    bot = users(:bender)
    bot.update!(email_address: "bender@example.test", password: "secret123456")
    sign_in bot
    get huddle_presence_users_url
    assert_json_error :forbidden, "Bots cannot join huddles"

    sign_in :david
    users(:david).banned!
    get huddle_presence_users_url
    assert_json_error :forbidden, "User cannot join huddles"
  end

  test "missing LiveKit configuration is reported" do
    sign_in :david
    ENV.delete("LIVEKIT_API_SECRET")

    get huddle_presence_users_url

    assert_json_error :service_unavailable, "Huddles are not configured"
  end

  private
    def issue_in_call_grant!(user:, room:, session: nil)
      session ||= user.sessions.find_by(user_agent: "Test") || user.sessions.create!(user_agent: "Test")
      membership = room.memberships.find_by!(user: user)

      HuddleGrant.issue!(session: session, membership: membership).tap do |grant|
        grant.update_columns(last_seen_at: Time.current)
      end
    end

    def assert_json_error(status, message)
      assert_response status
      assert_equal({ "error" => message }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]
    end

    def capture_select_sql(&block)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        queries << sql if sql.start_with?("SELECT") && !payload[:cached]
      end

      block.call
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
