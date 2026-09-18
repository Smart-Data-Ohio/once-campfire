require "application_system_test_case"
require "socket"
require "timeout"

class StageTest < ApplicationSystemTestCase
  self.use_transactional_tests = false

  SMARTFIRE_PORT = 3001
  GATEWAY_PORT = 7884

  # Same fixed port as the huddle suite, only for LiveKit-backed runs. See
  # test/system/huddles_test.rb.
  Capybara.server_port = SMARTFIRE_PORT if ENV["LIVEKIT_SYSTEM_TESTS"] == "1"

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ], options: { name: :stage_chrome } do |options|
    options.add_argument "--use-fake-device-for-media-stream"
    options.add_argument "--use-fake-ui-for-media-stream"
    options.add_argument "--autoplay-policy=no-user-gesture-required"
  end

  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    @original_livekit_url = ENV["LIVEKIT_URL"]
    @stage_rooms = []
    @stage_sessions = [ "default" ]

    if livekit_enabled?
      gateway_url = ENV["LIVEKIT_SYSTEM_TEST_GATEWAY_URL"].presence
      ENV["LIVEKIT_URL"] = gateway_url || "ws://127.0.0.1:#{GATEWAY_PORT}"
      @forgery_protection = ActionController::Base.allow_forgery_protection
      assert Huddle.configured?, "Source the LiveKit environment before running stage tests"
      HuddleCleanup.delete_all
      HuddleGrant.delete_all
      ActionController::Base.allow_forgery_protection = true
      start_gateway unless gateway_url
    else
      ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
      ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
      ENV["LIVEKIT_API_KEY"] = "test-api-key"
      ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
      ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
    end
  end

  teardown do
    begin
      @stage_sessions.each do |name|
        using_session(name) do
          if page.has_css?("#channel-huddle:not([hidden])", wait: 0)
            find("[data-action='huddle#leave']").click
            assert_no_selector "#channel-huddle:not([hidden])"
          end
        rescue Capybara::ElementNotFound
          nil
        end
      end
      @stage_rooms.each(&:destroy!)
    ensure
      if livekit_enabled?
        begin
          ActionController::Base.allow_forgery_protection = @forgery_protection
        ensure
          begin
            stop_gateway
          ensure
            begin
              @stage_rooms.each do |room|
                Huddle::RoomService.new.delete_room(room_name: Huddle.room_name(room.id))
              end
            ensure
              HuddleCleanup.delete_all
              HuddleGrant.delete_all
            end
          end
        end
      end
      ENV["LIVEKIT_URL"] = @original_livekit_url
      @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
    end
  end

  test "stage rooms list in their own section with distinct creation controls and a stage panel" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection

    assert_selector ".room-header__kind", text: /stage channel/i
    assert_selector ".huddle-launcher", text: "Join stage"
    assert_selector "#stage_rooms .stage-room", text: "Town Hall"
    assert_selector "#stage_rooms .stage-room .voice-stack:not(.voice-stack--live)"
    assert_no_selector "#voice_rooms .stage-room"
    within ".sidebar-section--voice" do
      assert_selector "h2", text: /\AVoice\z/i
      assert_selector "a.sidebar-section__add", count: 1
      assert_link "New voice channel", href: new_rooms_voice_path
    end
    within ".sidebar-section--stage" do
      assert_selector "h2", text: /\AStage\z/i
      assert_selector "a.sidebar-section__add", count: 1
      assert_link "New stage channel", href: new_rooms_stage_path
    end
    assert_no_selector "#shared_rooms .sidebar-item", text: "Town Hall"
    assert_selector ".room-header__actions .voice-stack"

    find("button[aria-label='Show stage']").click
    assert_selector ".stage-panel__surface h2", text: "Stage"
    within ".stage-panel__roster" do
      assert_selector "[aria-label='Hosts']", text: "David"
      assert_selector "[aria-label='Listeners']", text: "Jason"
    end
    assert_selector "##{dom_id(room, :stage_controls)}", text: "You are in the audience."

    find("button[aria-label='Close stage']").click
    assert_no_selector ".stage-panel__surface h2", text: "Stage"
  end

  test "a listener raises and lowers their hand without seeing host controls" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:kevin) ])
    sign_in "kevin@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    find("button[aria-label='Show stage']").click

    assert_no_selector "button", text: "Invite to speak", visible: :visible
    assert_no_selector "button", text: "Make host", visible: :visible
    assert_no_selector "button", text: "Move to audience", visible: :visible

    click_button "Raise hand"

    assert_selector "##{dom_id(room, :stage_controls)}", text: "Lower hand"
    kevin_row = "##{dom_id(room.memberships.find_by!(user: users(:kevin)), :stage_row)}"
    within kevin_row do
      assert_selector ".stage-panel__hand-badge", text: "Hand raised", wait: BROADCAST_WAIT
    end

    click_button "Lower hand"

    assert_selector "##{dom_id(room, :stage_controls)}", text: "Raise hand"
    within kevin_row do
      assert_no_selector ".stage-panel__hand-badge", wait: BROADCAST_WAIT
    end
  end

  test "raised hands appear in the host's panel live, in order" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason), users(:kevin) ])

    using_session("Host") do
      @stage_sessions << "Host"
      sign_in "david@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      find("button[aria-label='Show stage']").click
      assert_selector ".stage-panel__surface h2", text: "Stage"
    end

    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    find("button[aria-label='Show stage']").click
    click_button "Raise hand"
    assert_selector "##{dom_id(room, :stage_controls)}", text: "Lower hand"

    using_session("Kevin") do
      @stage_sessions << "Kevin"
      sign_in "kevin@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      find("button[aria-label='Show stage']").click
      click_button "Raise hand"
    end

    using_session("Host") do
      jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
      kevin_row = "##{dom_id(room.memberships.find_by!(user: users(:kevin)), :stage_row)}"

      within jason_row, wait: BROADCAST_WAIT do
        assert_selector ".stage-panel__hand-badge", text: "Hand raised", wait: BROADCAST_WAIT
        assert_selector "button", text: "Invite to speak", wait: BROADCAST_WAIT
      end
      within kevin_row do
        assert_selector "button", text: "Invite to speak", wait: BROADCAST_WAIT
      end

      first, second = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[aria-label='Listeners'] .stage-panel__member"))
          .map(element => element.id)
      JS
      assert_equal [ jason_row.delete_prefix("#"), kevin_row.delete_prefix("#") ], [ first, second ]
    end
  end

  test "a host invites a listener to speak and moves them back to the audience" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])

    using_session("Host") do
      @stage_sessions << "Host"
      sign_in "david@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      find("button[aria-label='Show stage']").click
    end

    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    find("button[aria-label='Show stage']").click
    click_button "Raise hand"
    assert_selector "##{dom_id(room, :stage_controls)}", text: "Lower hand"

    using_session("Host") do
      jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
      within jason_row, wait: BROADCAST_WAIT do
        assert_selector "button", text: "Invite to speak", wait: BROADCAST_WAIT
        click_button "Invite to speak"
      end

      within "[aria-label='Speakers']", wait: 10 do
        assert_selector ".stage-panel__member", text: "Jason"
      end
    end

    assert_selector "##{dom_id(room, :stage_controls)}", text: "You are speaking", wait: BROADCAST_WAIT

    using_session("Host") do
      jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
      within jason_row do
        click_button "Move to audience"
      end

      within "[aria-label='Listeners']", wait: 10 do
        assert_selector ".stage-panel__member", text: "Jason"
      end
    end

    assert_selector "##{dom_id(room, :stage_controls)}", text: "You are in the audience", wait: BROADCAST_WAIT
  end

  test "a host lowers a raised hand without promoting" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    room.memberships.find_by!(user: users(:jason)).raise_hand!

    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    find("button[aria-label='Show stage']").click

    jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
    within jason_row do
      click_button "Lower hand"
    end

    within jason_row, wait: BROADCAST_WAIT do
      assert_no_selector ".stage-panel__hand-badge", wait: BROADCAST_WAIT
    end
    within "[aria-label='Listeners']" do
      assert_selector ".stage-panel__member", text: "Jason"
    end
    assert_equal "listener", room.memberships.find_by!(user: users(:jason)).reload.stage_role
  end

  test "the last host cannot demote themselves from the panel" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    find("button[aria-label='Show stage']").click

    david_row = "##{dom_id(room.memberships.find_by!(user: users(:david)), :stage_row)}"
    within david_row do
      assert_selector "button[disabled][title='The stage needs at least one host']", text: "Move to audience"
    end

    jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
    within jason_row do
      click_button "Make host"
    end

    within david_row, wait: 10 do
      assert_selector "button:not([disabled])", text: "Move to audience"
    end
  end

  test "join stage dispatches huddle:join and toggles while connected" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    page.execute_script("window.stageJoinEvents = []; window.addEventListener('huddle:join', event => window.stageJoinEvents.push(event.detail))")

    click_button "Join stage"

    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("window.stageJoinEvents.length") > 0
    end
    assert_equal [ { "roomId" => room.id, "roomName" => "Town Hall", "canPublishHint" => false } ], page.evaluate_script("window.stageJoinEvents")

    page.execute_script(<<~JS, room.id)
      window.dispatchEvent(new CustomEvent("huddle:changed", {
        detail: { roomId: arguments[0], state: "connected" }
      }))
    JS

    assert_selector ".huddle-launcher", text: "Leave stage", wait: 10
    assert_equal "Leave stage", find(".huddle-launcher")["aria-label"]

    click_button "Leave stage"

    assert_equal [ { "roomId" => room.id, "roomName" => "Town Hall", "canPublishHint" => false } ], page.evaluate_script("window.stageJoinEvents")
    assert_selector ".huddle-launcher", text: "Join stage", wait: 10
    assert_selector "#channel-huddle[data-state='idle']", visible: :all
  end

  test "a listener joins without a microphone or device check" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:kevin) ])
    sign_in "kevin@37signals.com"
    visit room_path(room)
    wait_for_cable_connection

    assert_selector '.huddle-launcher[data-huddle-can-publish-param="false"]'

    # A first-time listener with no microphone: permission still prompts and
    # capture always fails. Without the LiveKit servers this join cannot
    # connect, but it must attempt to, not strand the listener in prejoin.
    page.execute_script(<<~JS)
      window.__stageGumCalls = 0
      window.__stageHuddleStates = []
      new MutationObserver(() => {
        window.__stageHuddleStates.push(document.getElementById("channel-huddle").dataset.state)
      }).observe(document.getElementById("channel-huddle"), { attributes: true, attributeFilter: [ "data-state" ] })
      // CI runs these tests with LiveKit reachable, so force the join to fail
      // at the credential step: the test is about what happens before and
      // after connecting, and "failed" is the only state with a retry control.
      const originalFetch = window.fetch
      window.fetch = (url, options) =>
        (typeof url === "string" && url.endsWith("/huddle") && options?.method === "POST")
          ? Promise.resolve(new Response("{}", { status: 503, headers: { "Content-Type": "application/json" } }))
          : originalFetch(url, options)
      navigator.permissions.query = () => Promise.resolve({ state: "prompt" })
      navigator.mediaDevices.getUserMedia = () => {
        window.__stageGumCalls += 1
        return Promise.reject(new DOMException("No microphone", "NotFoundError"))
      }
    JS

    click_button "Join stage"

    assert_selector "#channel-huddle[data-state='failed']", visible: :all, wait: 20
    assert_not_includes page.evaluate_script("window.__stageHuddleStates"), "prejoin"
    assert_equal 0, page.evaluate_script("window.__stageGumCalls")
  end

  test "a demoted speaker retries as a listener without entering prejoin" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:kevin) ])
    room.memberships.find_by!(user: users(:kevin)).change_stage_role!("speaker")
    sign_in "kevin@37signals.com"
    visit room_path(room)
    wait_for_cable_connection

    assert_selector '.huddle-launcher[data-huddle-can-publish-param="true"]'

    # A speaker with no microphone: the denial skips prejoin so the failed
    # join surfaces through the usual failure notice with a retry.
    page.execute_script(<<~JS)
      window.__stageGumCalls = 0
      window.__stageHuddleStates = []
      new MutationObserver(() => {
        window.__stageHuddleStates.push(document.getElementById("channel-huddle").dataset.state)
      }).observe(document.getElementById("channel-huddle"), { attributes: true, attributeFilter: [ "data-state" ] })
      // CI runs these tests with LiveKit reachable, so force the join to fail
      // at the credential step: the test is about what happens before and
      // after connecting, and "failed" is the only state with a retry control.
      const originalFetch = window.fetch
      window.fetch = (url, options) =>
        (typeof url === "string" && url.endsWith("/huddle") && options?.method === "POST")
          ? Promise.resolve(new Response("{}", { status: 503, headers: { "Content-Type": "application/json" } }))
          : originalFetch(url, options)
      navigator.permissions.query = () => Promise.resolve({ state: "denied" })
      navigator.mediaDevices.getUserMedia = () => {
        window.__stageGumCalls += 1
        return Promise.reject(new DOMException("No microphone", "NotFoundError"))
      }
    JS

    click_button "Join stage"
    assert_selector "#channel-huddle[data-state='failed']", visible: :all, wait: 20

    # The host demotes the speaker while the failed panel sits on the page.
    # The persistent role event carries the new role; consuming it refreshes
    # the stored retry hint and the page launcher, then rejoins once.
    page.execute_script(<<~JS, room.id)
      window.__stageHuddleStates = []
      const event = document.createElement("div")
      event.dataset.huddleRejoinRoomId = arguments[0]
      event.dataset.huddleRejoinStageRole = "listener"
      document.getElementById("huddle_role_events").appendChild(event)
    JS

    assert_selector '.huddle-launcher[data-huddle-can-publish-param="false"]', wait: 10
    wait_for_condition("the demotion did not trigger a rejoin") do
      page.evaluate_script("window.__stageHuddleStates").include?("connecting")
    end
    assert_selector "#channel-huddle[data-state='failed']", visible: :all, wait: 20

    # A first-time listener with no microphone: without the refreshed hint,
    # this retry would strand them in microphone prejoin.
    page.execute_script(<<~JS)
      window.__stageGumCalls = 0
      window.__stageHuddleStates = []
      navigator.permissions.query = () => Promise.resolve({ state: "prompt" })
    JS

    find("[data-huddle-target='retry']").click

    assert_selector "#channel-huddle[data-state='failed']", visible: :all, wait: 20
    assert_not_includes page.evaluate_script("window.__stageHuddleStates"), "prejoin"
    assert_equal 0, page.evaluate_script("window.__stageGumCalls")
    assert_selector '.huddle-launcher[data-huddle-can-publish-param="false"]'
  end

  test "stage rooms carry ordinary text chat" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection

    send_message "Hello from the stage"
    assert_message_text "Hello from the stage"
  end

  test "a listener joins subscribe-only while the host publishes" do
    skip "Run with LIVEKIT_SYSTEM_TESTS=1 and a configured LiveKit server" unless livekit_enabled?
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])

    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    join_stage_and_confirm

    assert_equal false, local_can_publish?
    assert_no_selector "#channel-huddle [data-huddle-target='mute']", visible: :visible
    assert_no_selector "#channel-huddle [data-huddle-target='share']", visible: :visible
    assert_no_selector "#channel-huddle [data-huddle-target='camera']", visible: :visible
    assert_selector "#channel-huddle [data-huddle-target='listeningNote']", text: "You are listening"

    using_session("Host") do
      @stage_sessions << "Host"
      sign_in "david@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      join_stage_and_confirm

      assert_equal true, local_can_publish?
      assert_selector "#channel-huddle [data-huddle-target='mute']", text: "Mute"
      assert_selector ".huddle__participant", count: 2
    end

    assert_selector ".huddle__participant", count: 2
  end

  test "inviting a listener to speak rejoins them publishing, and moving them back removes publish" do
    skip "Run with LIVEKIT_SYSTEM_TESTS=1 and a configured LiveKit server" unless livekit_enabled?
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])

    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    join_stage_and_confirm
    assert_equal false, local_can_publish?

    using_session("Host") do
      @stage_sessions << "Host"
      sign_in "david@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      find("button[aria-label='Show stage']").click

      jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
      within jason_row do
        click_button "Invite to speak"
      end
    end

    wait_for_condition("the invited listener did not rejoin publishing", timeout: LIVEKIT_REJOIN_WAIT) do
      page.has_css?("#channel-huddle[data-state='connected']", wait: 0) && local_can_publish? == true
    end
    assert_selector "#channel-huddle [data-huddle-target='mute']", text: "Mute", visible: :visible
    assert_no_selector "#channel-huddle [data-huddle-target='listeningNote']", visible: :visible

    using_session("Host") do
      jason_row = "##{dom_id(room.memberships.find_by!(user: users(:jason)), :stage_row)}"
      within jason_row, wait: 10 do
        click_button "Move to audience"
      end
    end

    wait_for_condition("the demoted speaker kept publishing", timeout: LIVEKIT_REJOIN_WAIT) do
      page.has_css?("#channel-huddle[data-state='connected']", wait: 0) && local_can_publish? == false
    end
    assert_selector "#channel-huddle [data-huddle-target='listeningNote']", text: "You are listening"
    assert_no_selector "#channel-huddle [data-huddle-target='mute']", visible: :visible
  end

  test "a listener survives a full reconnect and stays subscribe-only" do
    skip "Run with LIVEKIT_SYSTEM_TESTS=1 and a configured LiveKit server" unless livekit_enabled?
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])

    sign_in "jason@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    join_stage_and_confirm
    assert_equal false, local_can_publish?

    using_session("Host") do
      @stage_sessions << "Host"
      sign_in "david@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      join_stage_and_confirm
    end

    assert_selector ".huddle__participant", count: 2

    force_full_reconnect

    assert_selector "#channel-huddle[data-state='connected']", wait: 20
    wait_for_condition("the reconnected listener did not stay subscribe-only") do
      local_can_publish? == false
    end
    assert_selector "#channel-huddle [data-huddle-target='listeningNote']", text: "You are listening"
    assert_no_selector "#channel-huddle [data-huddle-target='mute']", visible: :visible
  end

  private
    def livekit_enabled?
      ENV["LIVEKIT_SYSTEM_TESTS"] == "1"
    end

    def create_stage_room(name:, members:)
      Rooms::Stage.create_for({ name:, creator: members.first }, users: members).tap do |room|
        @stage_rooms << room
      end
    end

    def join_stage_and_confirm
      click_button "Join stage"
      confirm_prejoin_if_present
      assert_selector "#channel-huddle[data-state='connected']", wait: 20
    end

    def confirm_prejoin_if_present
      wait_for_condition("the stage did not start joining") do
        %w[prejoin connecting connected].any? do |state|
          page.has_css?("#channel-huddle[data-state='#{state}']", wait: 0)
        end
      end
      return unless page.has_css?("#channel-huddle[data-state='prejoin']", wait: 0)

      assert_selector "[data-huddle-target='checkJoin']:not([disabled])", wait: 20
      find("[data-huddle-target='checkJoin']").click
    end

    def local_can_publish?
      page.evaluate_script(<<~JS)
        window.Stimulus
          .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle')
          ?.room?.localParticipant?.permissions?.canPublish ?? null
      JS
    end

    def force_full_reconnect
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        const controller = window.Stimulus
          .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle');
        controller.room.simulateScenario('full-reconnect')
          .then(() => done({ ok: true }))
          .catch(error => done({ ok: false, message: error.message }));
      JS
      assert result.fetch("ok"), "SDK could not start a full reconnect"
    end

    def start_gateway
      gateway_log_path = Rails.root.join("tmp/livekit-gateway-stage-test.log")
      @gateway_log = File.open(gateway_log_path, "w")
      environment = {
        "GATEWAY_CAMPFIRE_URL" => "http://127.0.0.1:#{SMARTFIRE_PORT}",
        "LIVEKIT_GATEWAY_PORT" => GATEWAY_PORT.to_s
      }
      @gateway_pid = Process.spawn(
        environment,
        "node", Rails.root.join("script/livekit-gateway/server.mjs").to_s,
        chdir: Rails.root.to_s,
        out: @gateway_log,
        err: @gateway_log,
        pgroup: true
      )
      wait_for_gateway(gateway_log_path)
    end

    def wait_for_gateway(log_path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10

      loop do
        begin
          TCPSocket.new("127.0.0.1", GATEWAY_PORT).close
          break
        rescue Errno::ECONNREFUSED
          if Process.waitpid(@gateway_pid, Process::WNOHANG)
            flunk "LiveKit gateway exited during startup:\n#{File.read(log_path)}"
          end
          flunk "LiveKit gateway did not start:\n#{File.read(log_path)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.05
        end
      end
    end

    def stop_gateway
      return unless @gateway_pid

      Process.kill("TERM", -@gateway_pid)
      Timeout.timeout(5) { Process.wait(@gateway_pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill("KILL", -@gateway_pid)
      Process.wait(@gateway_pid)
    ensure
      @gateway_log&.close
      @gateway_pid = nil
    end

    def wait_for_condition(message, timeout: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      assert true
    end
end
