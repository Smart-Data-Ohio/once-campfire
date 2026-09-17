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
    # presence broadcasts can arrive out of order and the issuance render
    # (nobody in voice yet) could land after the sighting render. Wait for
    # each issuance render before recording the sighting; in production,
    # issuance and first sighting are seconds apart.
    observe_turbo_stream_renders
    renders = header_voice_renders
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    wait_for_issuance_broadcast(after: renders)
    david_grant.record_seen!

    within "#voice_rooms .voice-room" do
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
    end

    renders = header_voice_renders
    jason_grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @room.memberships.find_by!(user: users(:jason)))
    wait_for_issuance_broadcast(after: renders)
    jason_grant.record_seen!

    within "#voice_rooms .voice-room" do
      assert_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_selector ".voice-stack__count", text: "2", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']", wait: BROADCAST_WAIT
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
      assert_selector ".voice-stack--live", wait: BROADCAST_WAIT
      assert_selector ".voice-stack__count", text: "2", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']", wait: BROADCAST_WAIT
    end

    assert_not ActivityItem.exists?(source: [ david_grant, jason_grant ])

    david_grant.revoke!

    within "#voice_rooms .voice-room" do
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
      assert_no_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:jason).id}']", wait: BROADCAST_WAIT
    end
    within ".room-header__actions" do
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
      assert_no_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']", wait: BROADCAST_WAIT
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
    assert_equal "Leave voice", find(".huddle-launcher")["aria-label"]

    click_button "Leave voice"

    assert_equal [], page.evaluate_script("window.huddleJoinEvents")
    assert_selector ".huddle-launcher", text: "Join voice", wait: 10
    assert_equal "Join voice", find(".huddle-launcher")["aria-label"]
    assert_selector "#channel-huddle[data-state='idle']", visible: :all
  end

  test "presence refreshes once quiet grants expire" do
    visit room_path(@room)
    wait_for_cable_connection

    stack = find(".room-header__actions .voice-stack")
    assert_equal "15000", stack["data-huddle-participants-interval-value"]

    observe_turbo_stream_renders
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    wait_for_issuance_broadcast # Let the issuance render land first (see above).
    grant.record_seen!

    within ".room-header__actions" do
      assert_selector ".voice-stack__count", text: "1", wait: BROADCAST_WAIT
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

  test "removing a member drops their sidebar row and header stack without errors" do
    visit room_path(@room)
    wait_for_cable_connection
    observe_turbo_stream_renders

    # The room page refreshes itself over the HeartbeatChannel reconnect, and
    # for a revoked membership that refresh 404s. That is pre-existing
    # closed-room behavior, silent in production (request.js ignores error
    # statuses), but the test harness raises server errors. Unsubscribe this
    # page's refresh subscription up front so only the removal behavior under
    # test is exercised. (A RefreshesController rescue would fix the harness
    # properly; that file is outside this task's scope.)
    page.execute_script(<<~JS)
      (() => {
        const element = document.querySelector('[data-controller~="refresh-room"]')
        window.Stimulus.getControllerForElementAndIdentifier(element, "refresh-room").disconnect()
      })()
    JS

    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    wait_for_issuance_broadcast
    david_grant.record_seen!
    within(".room-header__actions") { assert_selector ".voice-stack--live", wait: BROADCAST_WAIT }

    page.execute_script(<<~JS)
      window.voiceRemovalErrors = []
      window.addEventListener("error", event => window.voiceRemovalErrors.push(event.message))
      window.addEventListener("unhandledrejection", event => window.voiceRemovalErrors.push(String(event.reason)))
    JS

    using_session("Admin") do
      # The second session signs in and navigates while the first session's
      # cable churns; give its async landings the same budget as the test's
      # other waits instead of the 2s default.
      using_wait_time(10) do
        sign_in "david@37signals.com"
        visit edit_rooms_voice_path(@room)
        find("li[data-value='jason'] label.switch").click
        find("button.btn--reversed").click
        assert_selector ".room-header__name", text: "Lounge"
      end
    end

    # The sidebar row drops over the broadcast, or (when the test adapter
    # reorders the broadcast behind the connection reset) on the reconnect
    # reload a few seconds later.
    assert_no_selector "#voice_rooms .voice-room", text: "Lounge", wait: 15

    # The header stack usually drops over the same broadcast. If this run's
    # delivery reordered it behind the reset, drive the revoked poll instead:
    # the 404 clears the same stack in place. That refresh can be served a
    # still-live cached response from a poll just before the removal, so wait
    # for the stable end state (element gone, or controller revoked so no
    # later poll can re-render it) rather than one live-free instant.
    unless page.has_no_css?(".room-header__actions .voice-stack", wait: 5)
      page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1]
        const element = document.querySelector(".room-header__actions .voice-stack")
        const controller = element && window.Stimulus.getControllerForElementAndIdentifier(element, "huddle-participants")
        if (controller) controller.refresh().then(() => done("cleared"))
        else done("gone")
      JS
    end
    wait_for_stable_header_stack_removal
    assert_no_selector ".room-header__actions .voice-stack--live", wait: BROADCAST_WAIT

    # Let the post-removal cable reconnect play out: the room message stream
    # stays rejected while the sidebar streams resubscribe and the sidebar
    # frame reloads without the room.
    wait_for_connected_stream_sources(2)
    sleep 2
    assert_no_selector "#voice_rooms .voice-room", text: "Lounge"
    assert_no_selector ".room-header__actions .voice-stack--live"
    assert_equal [], page.evaluate_script("window.voiceRemovalErrors")
  end

  test "a participants 404 stops polling and clears the stack without retrying" do
    strangers_room = Rooms::Voice.create_for({ name: "Founders", creator: users(:david) }, users: [ users(:david) ])
    visit room_path(@room)
    wait_for_cable_connection

    page.execute_script(<<~JS)
      window.voiceRemovalErrors = []
      window.addEventListener("error", event => window.voiceRemovalErrors.push(event.message))
      window.addEventListener("unhandledrejection", event => window.voiceRemovalErrors.push(String(event.reason)))
      window.probeFetches = 0
      window.fetch = ((originalFetch) => (...args) => {
        const url = String(args[0] && args[0].url || args[0])
        if (url.includes("/huddle/participants")) window.probeFetches++
        return originalFetch(...args)
      })(window.fetch.bind(window))
    JS

    # A stale stack for a room Jason cannot access, as if he had just been
    # removed from it. The avatar carries no source: its presence alone is the
    # stale state under test.
    page.execute_script(<<~JS, participants_room_huddle_path(strangers_room), users(:david).id)
      document.body.insertAdjacentHTML("beforeend", `
        <span id="probe-voice-stack" class="voice-stack voice-stack--live" role="img" aria-label="1 in voice: David"
              data-controller="huddle-participants"
              data-huddle-participants-url-value="${arguments[0]}"
              data-huddle-participants-max-value="3"
              data-huddle-participants-interval-value="15000">
          <span class="voice-stack__avatars" data-huddle-participants-target="avatars">
            <img width="20" height="20" class="voice-stack__avatar" data-user-id="${arguments[1]}">
          </span>
          <span class="voice-stack__count" data-huddle-participants-target="count">1</span>
        </span>`)
    JS

    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        !!window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector("#probe-voice-stack"), "huddle-participants")
      JS
    end

    refresh_probe_stack
    assert_no_selector "#probe-voice-stack.voice-stack--live"
    within("#probe-voice-stack") do
      assert_no_selector "img.voice-stack__avatar"
      assert_selector "[data-huddle-participants-target='count'][hidden]", visible: :all
    end
    assert_equal 1, page.evaluate_script("window.probeFetches")

    refresh_probe_stack
    assert_equal 1, page.evaluate_script("window.probeFetches"), "a removed member must not be polled again"
    assert_equal [], page.evaluate_script("window.voiceRemovalErrors")
  end

  test "the voice header fits narrow phones and caps the stack" do
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    sleep 0.5
    david_grant.record_seen!
    jason_grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @room.memberships.find_by!(user: users(:jason)))
    sleep 0.5
    jason_grant.record_seen!

    visit room_path(@room)
    wait_for_cable_connection
    within(".room-header__actions") { assert_selector ".voice-stack--live .voice-stack__count", text: "2", wait: 10 }

    begin
      [ [ 320, 740 ], [ 390, 844 ] ].each do |width, height|
        page.current_window.resize_to(width, height)
        assert_no_horizontal_overflow
        assert_header_inside_viewport
      end

      # A fourth participant joins: the desktop header shows all four, the
      # phone header at most three plus the count.
      @room.memberships.grant_to([ users(:kevin), users(:jz) ])
      kevin_grant = HuddleGrant.issue!(session: users(:kevin).sessions.create!(user_agent: "Test"), membership: @room.memberships.find_by!(user: users(:kevin)))
      sleep 0.5
      kevin_grant.record_seen!
      jz_grant = HuddleGrant.issue!(session: users(:jz).sessions.create!(user_agent: "Test"), membership: @room.memberships.find_by!(user: users(:jz)))
      sleep 0.5
      jz_grant.record_seen!

      page.current_window.resize_to(1400, 1400)
      within(".room-header__actions") do
        assert_selector ".voice-stack__count", text: "4", wait: BROADCAST_WAIT
        assert_selector "img.voice-stack__avatar", count: 4, wait: BROADCAST_WAIT
      end

      # The narrowest phones have no room for the stack at all: it steps
      # aside instead of clipping, while wider phones cap it at three avatars
      # plus the count.
      page.current_window.resize_to(320, 740)
      assert_no_selector ".room-header__actions .voice-stack"
      assert_no_horizontal_overflow
      assert_header_inside_viewport

      page.current_window.resize_to(500, 800)
      within(".room-header__actions") do
        assert_selector "img.voice-stack__avatar", count: 3
        assert_selector ".voice-stack__count", text: "4"
      end
      assert_no_horizontal_overflow
      assert_header_inside_viewport
    ensure
      page.current_window.resize_to(1400, 1400)
    end
  end

  test "the room page shares one participants request across its stacks" do
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    sleep 0.5
    david_grant.record_seen!

    visit room_path(@room)
    wait_for_cable_connection
    assert_selector '[data-controller="huddle-participants"]', count: 2

    page.execute_script(<<~JS)
      window.probeFetches = 0
      window.fetch = ((originalFetch) => (...args) => {
        const url = String(args[0] && args[0].url || args[0])
        if (url.includes("/huddle/participants")) window.probeFetches++
        return originalFetch(...args)
      })(window.fetch.bind(window))
    JS

    fetch_count = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const controllers = [...document.querySelectorAll('[data-controller="huddle-participants"]')]
        .map(element => window.Stimulus.getControllerForElementAndIdentifier(element, "huddle-participants"))
      Promise.all(controllers.map(controller => controller.refresh())).then(() => done(window.probeFetches))
    JS

    assert_equal 1, fetch_count, "the sidebar and header stacks must share one request"
    within("#voice_rooms") do
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']"
    end
    within(".room-header__actions") do
      assert_selector "img.voice-stack__avatar[data-user-id='#{users(:david).id}']"
    end
  end

  private
    def assert_no_horizontal_overflow
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
        "the workspace overflows the viewport horizontally"
    end

    def assert_header_inside_viewport
      box, viewport = page.evaluate_script(<<~JS)
        [ document.querySelector("#nav").getBoundingClientRect().toJSON(), window.innerWidth ]
      JS
      assert_operator box["left"], :>=, 0, "the room header starts outside the viewport"
      assert_operator box["right"], :<=, viewport, "the room header ends outside the viewport"
    end

    def wait_for_connected_stream_sources(count)
      Timeout.timeout(25) do
        sleep 0.2 until page.evaluate_script(
          "document.querySelectorAll('turbo-cable-stream-source[connected]').length") == count
      end
    end

    # Records every Turbo Stream render as "action:target" so the test can
    # wait for a specific broadcast to land instead of sleeping a fixed time.
    def observe_turbo_stream_renders
      page.execute_script(<<~JS)
        window.voiceRemovalStreams = []
        document.addEventListener("turbo:before-stream-render", event => {
          window.voiceRemovalStreams.push(`${event.detail.newStream.action}:${event.detail.newStream.target}`)
        })
      JS
    end

    # The test cable adapter delivers over a thread pool, so back-to-back
    # presence broadcasts can arrive out of order and the issuance render
    # (nobody in voice yet) would win over the sighting render. Wait for the
    # issuance render to arrive before recording the sighting. Only the
    # header render is waited for: it travels the room stream on the main
    # page, while the sidebar render travels a user stream whose
    # subscription has a legitimate gap during the sidebar's initial
    # reload (rooms-list reconnects once on every page load).
    def wait_for_issuance_broadcast(after: 0)
      Timeout.timeout(10) do
        sleep 0.05 until header_voice_renders > after
      end
    end

    # Number of header participant renders observed so far; pass it as
    # `after:` so a later wait cannot be satisfied by an earlier render.
    def header_voice_renders
      expected = "replace:#{dom_id(@room, :header_voice_participants)}"
      page.evaluate_script("window.voiceRemovalStreams").count(expected)
    end

    # The header stack is stably clear once its element is gone (removal
    # broadcast) or its controller is revoked (participants 404): until then
    # an interval poll served from the shared cache can re-render it live. A
    # warm cache holds at most one poll cycle, so two cycles plus slack.
    def wait_for_stable_header_stack_removal
      Timeout.timeout(40) do
        sleep 0.1 until page.evaluate_script(<<~JS)
          (() => {
            const element = document.querySelector(".room-header__actions .voice-stack")
            if (!element) return true
            const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "huddle-participants")
            return !!controller && !!controller.revoked
          })()
        JS
      end
    end

    def refresh_probe_stack
      page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1]
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector("#probe-voice-stack"), "huddle-participants")
        controller.refresh().then(() => done("ok"))
      JS
    end
end
