require "application_system_test_case"
require "timeout"

class HuddleInvitationsTest < ApplicationSystemTestCase
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
    sign_in "jason@37signals.com"
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
  end

  test "the recipient sees an incoming huddle banner and dismissing it marks the item read" do
    visit room_path(rooms(:designers))
    wait_for_cable_connection

    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    item = ActivityItem.find_by!(user: users(:jason), source: grant)

    assert_selector "#huddle-invitation:not([hidden])", text: "David started a huddle", wait: 10
    assert_selector "#huddle-invitation:not([hidden])", text: "Join the huddle in David"
    assert_selector ".workspace-activity-count", text: "1", wait: 10

    within "#huddle-invitation" do
      click_button "Dismiss"
    end

    assert_selector "#huddle-invitation[hidden]", visible: :all, wait: 10
    assert_selector ".workspace-activity-count[hidden]", visible: :all, wait: 10
    assert_predicate item.reload, :read?
  end

  test "joining from the banner marks the item handled, navigates to the DM room, and rings the huddle panel" do
    visit room_path(rooms(:designers))
    wait_for_cable_connection
    page.execute_script("window.huddleJoinEvents = []; window.addEventListener('huddle:join', event => window.huddleJoinEvents.push(event.detail))")

    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    room = grant.room
    item = ActivityItem.find_by!(user: users(:jason), source: grant)

    assert_selector "#huddle-invitation:not([hidden])", wait: 10

    within "#huddle-invitation" do
      click_button "Join"
    end

    assert_current_path room_path(room), wait: 10
    assert_selector ".room--current", text: "David"

    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("window.huddleJoinEvents.length") > 0
    end
    assert_equal [ { "roomId" => room.id, "roomName" => "David" } ], page.evaluate_script("window.huddleJoinEvents")
    assert_predicate item.reload, :handled?
  end

  test "the banner stays hidden while already in the room's huddle" do
    visit room_path(rooms(:designers))
    wait_for_cable_connection

    room = rooms(:david_and_jason)
    page.execute_script(<<~JS, room.id)
      window.dispatchEvent(new CustomEvent("huddle:changed", {
        detail: { roomId: arguments[0], state: "connected" }
      }))
    JS

    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    item = ActivityItem.find_by!(user: users(:jason), source: grant)

    assert_no_selector "#huddle-invitation:not([hidden])", wait: 5
    assert_selector "#huddle-invitation[hidden]", visible: :all
    assert_predicate item.reload, :unread?
  end
end
