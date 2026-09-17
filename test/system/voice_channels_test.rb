require "application_system_test_case"
require "timeout"

class VoiceChannelsTest < ApplicationSystemTestCase
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
    sign_in "jason@37signals.com"

    @room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
  end

  test "the sidebar row and header show participants and update when a grant is revoked" do
    visit room_path(@room)
    wait_for_cable_connection

    assert_selector ".room-header__kind", text: /voice channel/i
    assert_selector ".huddle-launcher", text: "Join voice"
    assert_selector "#voice_rooms .voice-room", text: "Lounge"
    assert_selector "#voice_rooms .voice-room .voice-stack:not(.voice-stack--live)"

    # The test cable adapter delivers over a thread pool, so back-to-back
    # presence broadcasts can arrive out of order. The pauses below let each
    # broadcast land before the next one fires; in production, issuance and
    # first sighting are seconds apart.
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    sleep 0.5
    david_grant.record_seen!

    within "#voice_rooms .voice-room" do
      assert_selector ".voice-stack__count", text: "1", wait: 10
    end

    jason_grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @room.memberships.find_by!(user: users(:jason)))
    sleep 0.5
    jason_grant.record_seen!

    within "#voice_rooms .voice-room" do
      assert_selector ".voice-stack--live", wait: 10
      assert_selector ".voice-stack__count", text: "2"
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']"
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']"
    end

    # The presence stack sits at the row's trailing edge; if the row ever
    # matches the circle-button style again, its children stack on top of
    # each other instead.
    label_left, trailing_left = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector("#voice_rooms .voice-room");
        return [
          row.querySelector(".sidebar-item__label").getBoundingClientRect().left,
          row.querySelector(".voice-room__trailing").getBoundingClientRect().left
        ];
      })()
    JS
    assert_operator trailing_left, :>, label_left
    within ".room-header__actions" do
      assert_selector ".voice-stack--live", wait: 10
      assert_selector ".voice-stack__count", text: "2"
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']"
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']"
    end

    assert_not ActivityItem.exists?(source: [ david_grant, jason_grant ])

    david_grant.revoke!

    within "#voice_rooms .voice-room" do
      assert_selector ".voice-stack__count", text: "1", wait: 10
      assert_no_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']"
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']"
    end
    within ".room-header__actions" do
      assert_selector ".voice-stack__count", text: "1", wait: 10
      assert_no_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']"
    end
  end

  test "join voice dispatches huddle:join" do
    visit room_path(@room)
    wait_for_cable_connection
    page.execute_script("window.huddleJoinEvents = []; window.addEventListener('huddle:join', event => window.huddleJoinEvents.push(event.detail))")

    click_button "Join voice"

    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("window.huddleJoinEvents.length") > 0
    end
    assert_equal [ { "roomId" => @room.id, "roomName" => "Lounge" } ], page.evaluate_script("window.huddleJoinEvents")
  end

  test "the button toggles to leave voice while connected and leaves through the panel" do
    visit room_path(@room)
    wait_for_cable_connection
    page.execute_script("window.huddleJoinEvents = []; window.addEventListener('huddle:join', event => window.huddleJoinEvents.push(event.detail))")

    page.execute_script(<<~JS, @room.id)
      window.dispatchEvent(new CustomEvent("huddle:changed", {
        detail: { roomId: arguments[0], state: "connected" }
      }))
    JS

    assert_selector ".huddle-launcher", text: "Leave voice", wait: 10

    click_button "Leave voice"

    assert_equal [], page.evaluate_script("window.huddleJoinEvents")
    assert_selector ".huddle-launcher", text: "Join voice", wait: 10
    assert_selector "#channel-huddle[data-state='idle']", visible: :all
  end

  test "presence refreshes once quiet grants expire" do
    visit room_path(@room)
    wait_for_cable_connection

    stack = find(".room-header__actions .voice-stack")
    assert_equal "15000", stack["data-huddle-participants-interval-value"]

    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    sleep 0.5 # Let the issuance broadcast land first (see above).
    grant.record_seen!

    within ".room-header__actions" do
      assert_selector ".voice-stack__count", text: "1", wait: 10
    end

    # The grant quietly expires: no broadcast fires, so the stack goes stale
    # until the next refresh.
    grant.update_columns(last_seen_at: 1.minute.ago)
    assert_selector ".room-header__actions .voice-stack__count", text: "1", wait: 0

    assert_no_selector ".room-header__actions .voice-stack--live", wait: 25
    assert_selector ".room-header__actions .voice-stack__count[hidden]", visible: :all, wait: 10
  end

  test "voice rooms carry ordinary text chat" do
    visit room_path(@room)
    wait_for_cable_connection

    send_message "Hello from the voice lounge"
    assert_message_text "Hello from the voice lounge"
  end
end
