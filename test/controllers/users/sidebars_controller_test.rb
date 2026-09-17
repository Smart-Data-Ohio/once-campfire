require "test_helper"

class Users::SidebarsControllerTest < ActionDispatch::IntegrationTest
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

  test "show" do
    get user_sidebar_url

    users(:david).rooms.opens.each do |room|
      assert_match /#{room.name}/, @response.body
    end
  end

  test "unread directs" do
    rooms(:david_and_jason).messages.create! client_message_id: 999, body: "Hello", creator: users(:jason)

    get user_sidebar_url
    assert_select ".unread", count: users(:david).memberships.select { |m| m.room.direct? && m.unread? }.count
  end


  test "unread other" do
    rooms(:watercooler).messages.create! client_message_id: 999, body: "Hello", creator: users(:jason)

    get user_sidebar_url
    assert_select ".unread", count: users(:david).memberships.reject { |m| m.room.direct? || !m.unread? }.count
  end

  test "channel row shows the live huddle stack with names and count" do
    room = rooms(:watercooler)
    issue_in_call_grant!(user: users(:david), room: room)
    issue_in_call_grant!(user: users(:jason), room: room)

    get user_sidebar_url

    assert_response :success
    assert_select "##{dom_id(room, :list)} .voice-stack--live.voice-stack--huddle" do
      assert_select ".voice-stack__count", text: "2"
      assert_select "img.voice-stack__avatar[data-user-id='#{users(:david).id}'][title='David']"
      assert_select "img.voice-stack__avatar[data-user-id='#{users(:jason).id}'][title='Jason']"
    end
    assert_select "##{dom_id(room, :list)} .voice-stack" +
      "[aria-label='2 in huddle: David and Jason'][title='2 in huddle: David and Jason']" +
      "[data-huddle-participants-interval-value='0'][data-huddle-participants-label-value='in huddle']" +
      "[data-huddle-presence-room-id='#{room.id}']"
  end

  test "board row shows the live huddle stack with names and count" do
    board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) }, users: [ users(:david), users(:jz) ])
    issue_in_call_grant!(user: users(:david), room: board)
    issue_in_call_grant!(user: users(:jz), room: board)

    get user_sidebar_url

    assert_response :success
    assert_select "##{dom_id(board, :list)} .voice-room__trailing .voice-stack--live.voice-stack--huddle" do
      assert_select ".voice-stack__count", text: "2"
      assert_select "img.voice-stack__avatar[data-user-id='#{users(:david).id}'][title='David']"
      assert_select "img.voice-stack__avatar[data-user-id='#{users(:jz).id}'][title='JZ']"
    end
    assert_select "##{dom_id(board, :list)} .voice-stack" +
      "[aria-label='2 in huddle: David and JZ'][title='2 in huddle: David and JZ']" +
      "[data-huddle-participants-interval-value='0'][data-huddle-participants-label-value='in huddle']" +
      "[data-huddle-presence-room-id='#{board.id}']"
  end

  test "direct row shows the live huddle stack when the peer is in the call" do
    room = rooms(:david_and_jason)
    issue_in_call_grant!(user: users(:jason), room: room)

    get user_sidebar_url

    assert_response :success
    assert_select "##{dom_id(room, :list)} .voice-stack--live" do
      assert_select ".voice-stack__count", text: "1"
      assert_select "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']"
    end
    assert_select "##{dom_id(room, :list)} .voice-stack[aria-label='1 in huddle: Jason']"
  end

  test "quiet rows keep an empty stack target with no visible presence" do
    get user_sidebar_url

    assert_response :success
    assert_select "##{dom_id(rooms(:watercooler), :list)} .voice-stack:not(.voice-stack--live)" +
      "[aria-label='Nobody in huddle']" do
      assert_select ".voice-stack__avatar", count: 0
      assert_select ".voice-stack__count[hidden]", text: "0", visible: false
    end
    assert_select "##{dom_id(rooms(:david_and_jason), :list)} .voice-stack:not(.voice-stack--live)" +
      "[aria-label='Nobody in huddle']"
  end

  test "group direct rooms render no stack" do
    group = Rooms::Direct.create_for({ creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    issue_in_call_grant!(user: users(:jason), room: group)

    get user_sidebar_url

    assert_response :success
    assert_select "##{dom_id(group, :list)}", text: "Ping with J+K"
    assert_select "##{dom_id(group, :list)} .voice-stack", count: 0
  end

  test "no channel or DM stacks without huddle configuration" do
    ENV.delete("LIVEKIT_GATEWAY_SECRET")
    issue_in_call_grant!(user: users(:jason), room: rooms(:watercooler))

    get user_sidebar_url

    assert_response :success
    assert_select "#shared_rooms .voice-stack", count: 0
    assert_select "#direct_rooms .voice-stack", count: 0
    assert_select "[data-controller~='huddle-presence']", count: 0
  end

  test "sidebar query count does not grow with quiet channels, DMs, and boards" do
    2.times { |index| create_quiet_channel("Quiet #{index}") }
    create_quiet_direct(users(:jz))
    create_quiet_board("Quiet board")
    get user_sidebar_url # Warm up one-time queries before counting.
    baseline = capture_select_sql { get user_sidebar_url }
    assert_response :success

    4.times { |index| create_quiet_channel("Extra quiet #{index}") }
    create_quiet_direct(users(:bender))
    create_quiet_direct(users(:kevin))
    create_quiet_board("Extra quiet board")
    with_more_rooms = capture_select_sql { get user_sidebar_url }
    assert_response :success

    assert_equal baseline.count, with_more_rooms.count,
      "expected no per-row queries, saw #{with_more_rooms.count - baseline.count} more:\n#{(with_more_rooms - baseline).join("\n")}"
    assert_equal 1, with_more_rooms.count { |sql| sql.include?("FROM \"huddle_grants\"") }
  end

  private
    def issue_in_call_grant!(user:, room:)
      session = user.sessions.find_by(user_agent: "Test") || user.sessions.create!(user_agent: "Test")
      HuddleGrant.issue!(session: session, membership: room.memberships.find_by!(user: user)).tap do |grant|
        grant.update_columns(last_seen_at: Time.current)
      end
    end

    def create_quiet_channel(name)
      Rooms::Closed.create_for({ name: name, creator: users(:david) }, users: [ users(:david) ])
    end

    def create_quiet_direct(peer)
      Rooms::Direct.create_for({ creator: users(:david) }, users: [ users(:david), peer ])
    end

    def create_quiet_board(name)
      Rooms::Board.create_for({ name: name, creator: users(:david) }, users: [ users(:david) ])
    end

    # Cached reads count too: per-row queries carry distinct binds, so they
    # can never hide in the query cache, while the surrounding sidebar
    # queries stay identical between the two renders either way.
    def capture_select_sql(&block)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        queries << sql if sql.start_with?("SELECT") && payload[:name] != "SCHEMA"
      end

      block.call
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
