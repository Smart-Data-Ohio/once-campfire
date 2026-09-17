require "application_system_test_case"

class UnreadRoomsTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
  end

  test "sending messages between two users" do
    designers_room = rooms(:designers)
    hq_room = rooms(:hq)

    join_room hq_room
    assert_room_read hq_room

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room designers_room
      send_message("Hello!!")
      send_message("Talking to myself?")
    end

    assert_room_unread designers_room

    join_room designers_room
    assert_room_read designers_room
  end

  test "channel and DM rows keep exactly one unread badge next to the huddle stack" do
    with_huddle_configured do
      channel = rooms(:designers)
      direct = Rooms::Direct.create_for({ creator: users(:jz) }, users: [ users(:jz), users(:kevin) ])

      join_room rooms(:hq)

      # Signing in lands on a room and connects its membership, and a
      # membership stays "connected" for 60 seconds, during which the server
      # skips it when marking unread. Expire that grace period so the channel
      # unread below persists server-side and survives the reload.
      users(:jz).memberships.find_by!(room: channel).update_columns(connected_at: nil, connections: 0)

      using_session("Kevin") do
        sign_in "kevin@37signals.com"
        join_room channel
        send_message("Channel one")
        join_room direct
        send_message("DM one")
      end

      assert_single_badge channel
      assert_single_badge direct

      # Reload so the badges render on the server, then a second wave arrives
      # over the cable: the read/unread handler must reuse the rendered badge
      # instead of appending a duplicate next to it.
      visit room_path(rooms(:hq))
      wait_for_cable_connection
      assert_single_badge channel
      assert_single_badge direct

      using_session("Kevin") do
        send_message("DM two")
        join_room channel
        send_message("Channel two")
      end

      assert_single_badge channel
      assert_single_badge direct
      assert_badge_beside_stack channel
      assert_badge_beside_stack direct

      join_room channel
      assert_no_badge channel

      join_room direct
      assert_no_badge direct
    end
  end

  private
    def with_huddle_configured(&block)
      names = Huddle::REQUIRED_ENVIRONMENT
      original = ENV.values_at(*names)
      ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
      ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
      ENV["LIVEKIT_API_KEY"] = "test-api-key"
      ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
      ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"

      block.call
    ensure
      names.zip(original).each { |name, value| ENV[name] = value }
    end

    def assert_single_badge(room)
      within "##{dom_id(room, :list)}" do
        assert_selector ".sidebar-item__status", count: 1, wait: 5
      end
    end

    def assert_no_badge(room)
      within "##{dom_id(room, :list)}" do
        assert_no_selector ".sidebar-item__status", wait: 5
      end
    end

    # The badge is a direct child of the row (where the read/unread handler
    # looks for it) and the row lays out four columns (icon, label, stack,
    # badge) so the badge sits beside the stack instead of wrapping below it.
    def assert_badge_beside_stack(room)
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const row = document.getElementById("#{dom_id(room, :list)}");
          return {
            badgeDirect: !!row.querySelector(":scope > .sidebar-item__status"),
            columns: getComputedStyle(row).gridTemplateColumns.split(" ").length
          };
        })()
      JS

      assert geometry["badgeDirect"], "expected the unread badge to be a direct child of #{dom_id(room, :list)}"
      assert_equal 4, geometry["columns"],
        "expected icon, label, stack, and badge columns in #{dom_id(room, :list)}"
    end
end
