require "application_system_test_case"
require "timeout"

class HuddlePresenceTest < ApplicationSystemTestCase
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
    sign_in "jason@37signals.com"

    @room = rooms(:designers)
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
  end

  test "the channel sidebar row and header show participants and empty on revoke" do
    visit room_path(@room)
    wait_for_cable_connection

    assert_selector "#shared_rooms .sidebar-item", text: "Designers"
    within "##{dom_id(@room, :list)}" do
      assert_selector ".voice-stack:not(.voice-stack--live)", visible: :all
    end

    observe_turbo_stream_renders
    renders = header_presence_renders
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    wait_for_issuance_broadcast(after: renders)
    grant.record_seen!

    within "##{dom_id(@room, :list)}" do
      assert_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
    end
    assert_equal "1 in huddle: David", find("##{dom_id(@room, :list)} .voice-stack")["aria-label"]
    within ".room-header__actions" do
      assert_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
    end

    grant.revoke!

    within "##{dom_id(@room, :list)}" do
      assert_no_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_no_selector "img.voice-stack__avatar", wait: BROADCAST_WAIT
    end
    within ".room-header__actions" do
      assert_no_selector ".voice-stack--live", wait: BROADCAST_WAIT
    end
  end

  test "the DM sidebar row and header show the peer and empty on revoke" do
    direct_room = rooms(:david_and_jason)
    visit room_path(direct_room)
    wait_for_cable_connection

    observe_turbo_stream_renders
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: direct_room.memberships.find_by!(user: users(:david)))
    wait_for_issuance_broadcast(room: direct_room)
    grant.record_seen!

    within "##{dom_id(direct_room, :list)}" do
      assert_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
    end
    within ".room-header__actions" do
      assert_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
    end

    grant.revoke!

    within "##{dom_id(direct_room, :list)}" do
      assert_no_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_no_selector "img.voice-stack__avatar", wait: BROADCAST_WAIT
    end
    within ".room-header__actions" do
      assert_no_selector ".voice-stack--live", wait: BROADCAST_WAIT
    end
  end

  test "the sidebar aggregate poll clears quietly expired grants" do
    visit room_path(@room)
    wait_for_cable_connection

    sidebar_stack = find("##{dom_id(@room, :list)} .voice-stack", visible: :all)
    assert_equal "0", sidebar_stack["data-huddle-participants-interval-value"]
    header_stack = find(".room-header__actions .voice-stack", visible: :all)
    assert_equal "15000", header_stack["data-huddle-participants-interval-value"]

    observe_turbo_stream_renders
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    wait_for_issuance_broadcast
    grant.record_seen!

    within "##{dom_id(@room, :list)}" do
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
    end

    page.execute_script(<<~JS)
      window.presenceFetches = 0
      window.fetch = ((originalFetch) => (...args) => {
        const url = String(args[0] && args[0].url || args[0])
        if (url.includes("/users/huddle_presence")) window.presenceFetches++
        return originalFetch(...args)
      })(window.fetch.bind(window))
    JS

    # The grant quietly expires: no broadcast fires, so the sidebar row goes
    # stale until the next aggregate poll.
    grant.update_columns(last_seen_at: 1.minute.ago)
    assert_selector "##{dom_id(@room, :list)} .voice-stack__count", text: "1", wait: 0

    within "##{dom_id(@room, :list)}" do
      assert_no_selector ".voice-stack--live", wait: 30
    end
    assert_operator page.evaluate_script("window.presenceFetches"), :>=, 1,
      "the sidebar never ran its aggregate presence poll"
  end

  test "the sidebar aggregate poll runs on connect and skips in-flight refreshes" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    grant.record_seen!

    visit room_path(@room)
    wait_for_cable_connection

    within "##{dom_id(@room, :list)}" do
      assert_selector ".voice-stack--live .voice-stack__count", text: "1"
    end

    # The grant quietly expires: no broadcast fires, so the sidebar row goes
    # stale until a poll runs.
    grant.update_columns(last_seen_at: 1.minute.ago)
    assert_selector "##{dom_id(@room, :list)} .voice-stack__count", text: "1", wait: 0

    page.execute_script(<<~JS)
      window.presenceFetches = 0
      window.fetch = ((originalFetch) => (...args) => {
        const url = String(args[0] && args[0].url || args[0])
        if (url.includes("/users/huddle_presence")) window.presenceFetches++
        return originalFetch(...args)
      })(window.fetch.bind(window))
    JS

    # A reconnected sidebar (restored frame, fresh subscription) polls
    # immediately through the real connect() instead of waiting out the
    # 15-second interval; the header stack's own interval cannot explain a
    # clear this fast, and it polls a different URL anyway.
    page.execute_script(<<~JS)
      const element = document.querySelector('[data-controller~="huddle-presence"]')
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "huddle-presence")
      controller.disconnect()
      controller.connect()
    JS

    within "##{dom_id(@room, :list)}" do
      assert_no_selector ".voice-stack--live", wait: 10
    end
    assert_operator page.evaluate_script("window.presenceFetches"), :>=, 1,
      "reconnecting the sidebar never ran its aggregate presence poll"

    # Two refreshes issued back to back share one request: the second sees
    # the first still in flight and skips itself.
    page.execute_script(<<~JS)
      window.presenceFetches = 0
      const element = document.querySelector('[data-controller~="huddle-presence"]')
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "huddle-presence")
      controller.refresh()
      controller.refresh()
    JS
    Timeout.timeout(10) do
      sleep 0.05 until page.evaluate_script("window.presenceFetches") >= 1
    end
    sleep 0.5
    assert_equal 1, page.evaluate_script("window.presenceFetches"),
      "back-to-back refreshes issued duplicate aggregate polls"
  end

  test "a removed sidebar stack clears once but keeps accepting updates while the header latches" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    grant.record_seen!

    visit room_path(@room)
    wait_for_cable_connection

    within "##{dom_id(@room, :list)}" do
      assert_selector ".voice-stack--live .voice-stack__count", text: "1"
    end
    within ".room-header__actions" do
      assert_selector ".voice-stack--live .voice-stack__count", text: "1"
    end

    # A 404 on one stack dispatches a removal for the shared participants
    # URL; both stacks clear.
    page.execute_script(<<~JS, participants_room_huddle_path(@room))
      const [ url ] = arguments
      window.dispatchEvent(new CustomEvent("huddle-participants:removed", { detail: { url } }))
    JS

    within "##{dom_id(@room, :list)}" do
      assert_no_selector ".voice-stack--live"
    end
    within ".room-header__actions" do
      assert_no_selector ".voice-stack--live"
    end

    # The next aggregate update revives the externally fed sidebar stack, but
    # the polling header stack stays latched.
    david = users(:david)
    page.execute_script(<<~JS, participants_room_huddle_path(@room), [ { id: david.id, name: david.name, avatar_url: fresh_user_avatar_path(david) } ])
      const [ url, participants ] = arguments
      window.dispatchEvent(new CustomEvent("huddle-participants:updated", { detail: { url, participants } }))
    JS

    within "##{dom_id(@room, :list)}" do
      assert_selector ".voice-stack--live .voice-stack__count", text: "1"
      assert_selector "img.voice-stack__avatar[data-user-id='#{david.id}']"
    end
    within ".room-header__actions" do
      assert_no_selector ".voice-stack--live"
    end
  end

  private
    # Records every Turbo Stream render as "action:target" so the test can
    # wait for a specific broadcast to land instead of sleeping a fixed time.
    def observe_turbo_stream_renders
      page.execute_script(<<~JS)
        window.presenceObservedStreams = []
        document.addEventListener("turbo:before-stream-render", event => {
          window.presenceObservedStreams.push(`${event.detail.newStream.action}:${event.detail.newStream.target}`)
        })
      JS
    end

    # The test cable adapter delivers over a thread pool, so back-to-back
    # presence broadcasts can arrive out of order and the issuance render
    # (nobody in the huddle yet) would win over the sighting render. Wait for
    # the issuance render to arrive before recording the sighting.
    def wait_for_issuance_broadcast(after: 0, room: @room)
      Timeout.timeout(10) do
        sleep 0.05 until header_presence_renders(room: room) > after
      end
    end

    def header_presence_renders(room: @room)
      expected = "replace:#{dom_id(room, :header_voice_participants)}"
      page.evaluate_script("window.presenceObservedStreams").count(expected)
    end
end
