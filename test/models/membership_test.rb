require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:david_watercooler)

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

  test "connected scope" do
    @membership.connected
    assert Membership.connected.exists?(@membership.id)

    @membership.disconnected
    assert_not Membership.connected.exists?(@membership.id)

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert_not Membership.connected.exists?(@membership.id)
  end

  test "disconnected scope" do
    @membership.disconnected
    assert Membership.disconnected.exists?(@membership.id)

    @membership.connected
    assert_not Membership.disconnected.exists?(@membership.id)

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert Membership.disconnected.exists?(@membership.id)
  end

  test "connected? is false when connection is stale" do
    @membership.connected
    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert_not @membership.connected?
  end

  test "connecting" do
    @membership.connected
    assert @membership.connected?
    assert_equal 1, @membership.connections

    @membership.connected
    assert_equal 2, @membership.connections
  end

  test "connecting resets stale connection count" do
    2.times { @membership.connected }
    assert_equal 2, @membership.connections

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    @membership.connected
    assert_equal 1, @membership.connections
  end

  test "disconnecting" do
    2.times { @membership.connected }

    @membership.disconnected
    assert @membership.connected?
    assert_equal 1, @membership.connections

    @membership.disconnected
    assert_not @membership.connected?
    assert_equal 0, @membership.connections
  end

  test "disconnecting resets stale connection count" do
    2.times { @membership.connected }
    assert_equal 2, @membership.connections

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    @membership.disconnected
    assert_equal 0, @membership.connections
  end

  test "refreshing the connection" do
    @membership.connected

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert_not @membership.connected?

    @membership.refresh_connection
    assert @membership.connected?
  end

  test "removing a membership resets the user's connections" do
    @membership.user.expects :reset_remote_connections

    @membership.destroy
  end

  test "a failed removal broadcast still resets the user's connections" do
    @membership.stubs(:broadcast_remove_to).raises(RuntimeError, "cable down")
    @membership.user.expects :reset_remote_connections

    assert_nothing_raised { @membership.destroy }
    assert @membership.destroyed?
  end

  test "removing an open channel member drops their header stack and sidebar row" do
    assert_removal_drops_header_stack_and_row memberships(:david_hq)
  end

  test "removing a closed channel member drops their header stack and sidebar row" do
    assert_removal_drops_header_stack_and_row memberships(:david_watercooler)
  end

  test "removing a direct member drops their header stack and sidebar row" do
    assert_removal_drops_header_stack_and_row memberships(:david_david_and_jason)
  end

  test "removal drops only the sidebar row without huddle configuration" do
    ENV.delete("LIVEKIT_GATEWAY_SECRET")
    membership = memberships(:david_watercooler)

    membership.destroy!

    removed = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
    assert_equal [ "remove" ], removed.map { |stream| stream["action"] }
    assert_equal [ dom_id(membership.room, :list) ], removed.map { |stream| stream["target"] }
  end

  private
    def assert_removal_drops_header_stack_and_row(membership)
      room, user = membership.room, membership.user

      membership.destroy!

      removed = capture_turbo_stream_broadcasts([ user, :rooms ])
      assert_equal [ "remove", "remove" ], removed.map { |stream| stream["action"] }
      assert_equal [ dom_id(room, :header_voice_participants), dom_id(room, :list) ],
        removed.map { |stream| stream["target"] }
    end
end
