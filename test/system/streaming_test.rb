require "application_system_test_case"
require "socket"
require "timeout"

class StreamingTest < ApplicationSystemTestCase
  self.use_transactional_tests = false

  CAMPFIRE_PORT = 3001
  GATEWAY_PORT = 7884

  # Same fixed port as the huddle suite, only for LiveKit-backed runs. See
  # test/system/huddles_test.rb.
  Capybara.server_port = CAMPFIRE_PORT if ENV["LIVEKIT_SYSTEM_TESTS"] == "1"

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ], options: { name: :streaming_chrome } do |options|
    options.add_argument "--use-fake-device-for-media-stream"
    options.add_argument "--use-fake-ui-for-media-stream"
    options.add_argument "--autoplay-policy=no-user-gesture-required"
  end

  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    @original_livekit_url = ENV["LIVEKIT_URL"]
    @stream_rooms = []
    @stream_sessions = [ "default" ]

    # The cancelled-capture path DELETEs through fetch with the CSRF token,
    # so forgery protection stays on for every test here, not just the
    # LiveKit-backed one: without it the token meta tag never renders.
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    if livekit_enabled?
      gateway_url = ENV["LIVEKIT_SYSTEM_TEST_GATEWAY_URL"].presence
      ENV["LIVEKIT_URL"] = gateway_url || "ws://127.0.0.1:#{GATEWAY_PORT}"
      assert Huddle.configured?, "Source the LiveKit environment before running streaming tests"
      HuddleCleanup.delete_all
      HuddleGrant.delete_all
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
      @stream_sessions.each do |name|
        using_session(name) do
          if page.has_css?("#channel-huddle:not([hidden])", wait: 0)
            find("[data-action='huddle#leave']").click
            assert_no_selector "#channel-huddle:not([hidden])"
          end
        rescue Capybara::ElementNotFound
          nil
        end
      end
      @stream_rooms.each(&:destroy!)
    ensure
      begin
        ActionController::Base.allow_forgery_protection = @forgery_protection
      ensure
        if livekit_enabled?
          begin
            stop_gateway
          ensure
            begin
              @stream_rooms.each do |room|
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

  test "going live posts the stream and dispatches huddle:stream-start with the chosen quality" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    join_stage_without_media(room, users(:david))
    find("button[aria-label='Show stage']").click
    page.execute_script("window.streamStartEvents = []; window.addEventListener('huddle:stream-start', event => window.streamStartEvents.push(event.detail))")

    select "1080p30", from: "Stream quality"
    click_button "Go live"

    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until page.evaluate_script("window.streamStartEvents.length") > 0
    end
    assert_equal [ { "roomId" => room.id, "quality" => "1080p30" } ], page.evaluate_script("window.streamStartEvents")

    assert_predicate Stream.find_by(room_id: room.id), :live?
    assert_selector ".stage-live__badge", text: "Live: David"
    assert_selector "#voice_rooms .stage-room .stage-live-dot__pip"
    assert_selector ".stage-panel__note--live", text: "Live: David"
    assert_selector "button", text: "Stop stream"
  end

  test "the Go live control stays disabled until the huddle connects to the room" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    find("button[aria-label='Show stage']").click

    assert_button "Go live", disabled: true

    dispatch_huddle_changed(room_id: room.id + 1000, state: "connected")
    assert_button "Go live", disabled: true

    dispatch_huddle_changed(room_id: room.id, state: "connecting")
    assert_button "Go live", disabled: true

    dispatch_huddle_changed(room_id: room.id, state: "connected")
    assert_button "Go live", disabled: false

    dispatch_huddle_changed(room_id: room.id, state: "idle")
    assert_button "Go live", disabled: true
  end

  test "the huddle controller maps stream quality to screen-share presets" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection

    # The real LiveKit SDK loads without a server; only the room is faked, so
    # the asserted encodings are the SDK's own presets, not test fixtures.
    result = page.evaluate_async_script(<<~JS, room.id)
      const done = arguments[arguments.length - 1];
      import("livekit-client").then(module => {
        const controller = window.Stimulus
          .getControllerForElementAndIdentifier(document.getElementById("channel-huddle"), "huddle");
        controller.liveKit = module;
        controller.roomId = arguments[0];
        controller.state = "connected";
        window.__streamPublishCalls = [];
        controller.room = {
          localParticipant: {
            isMicrophoneEnabled: true,
            isScreenShareEnabled: false,
            isCameraEnabled: false,
            trackPublications: new Map(),
            setScreenShareEnabled: (enabled, capture, publish) => {
              const encoding = publish?.screenShareEncoding;
              window.__streamPublishCalls.push({
                enabled: enabled,
                encoding: encoding ? { maxBitrate: encoding.maxBitrate, maxFramerate: encoding.maxFramerate } : null
              });
              return Promise.resolve({});
            }
          }
        };
        done(true);
      }).catch(error => done({ error: String(error && error.message || error) }));
    JS
    assert_equal true, result

    { "720p15" => [ 1_500_000, 15 ], "1080p15" => [ 2_500_000, 15 ], "1080p30" => [ 5_000_000, 30 ] }.each do |quality, (bitrate, fps)|
      page.execute_script(<<~JS, room.id, quality)
        window.dispatchEvent(new CustomEvent("huddle:stream-start", {
          detail: { roomId: arguments[0], quality: arguments[1] }
        }));
      JS

      wait_for_condition("the #{quality} stream did not start sharing") do
        page.evaluate_script("window.__streamPublishCalls.length") > 0
      end

      call = page.evaluate_script("window.__streamPublishCalls.shift()")
      assert_equal true, call["enabled"]
      assert_equal bitrate, call["encoding"]["maxBitrate"]
      assert_equal fps, call["encoding"]["maxFramerate"]
    end
  end

  test "a cancelled capture DELETEs the stream" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:jason) ])
    Stream.create!(room: room, membership: room.memberships.find_by!(user: users(:david)),
      user: users(:david), quality: "1080p15")
    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection

    assert_selector ".stage-live__badge", text: "Live: David"

    page.execute_script(<<~JS, room.id)
      window.__streamDeleteSeen = [];
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (typeof url === "string" && url.endsWith("/stage/stream") && options?.method === "DELETE") {
          window.__streamDeleteSeen.push(url);
        }
        return originalFetch(url, options);
      };
      const controller = window.Stimulus
        .getControllerForElementAndIdentifier(document.getElementById("channel-huddle"), "huddle");
      controller.roomId = arguments[0];
      controller.state = "connected";
      controller.room = {
        localParticipant: {
          isMicrophoneEnabled: true,
          isScreenShareEnabled: false,
          isCameraEnabled: false,
          trackPublications: new Map(),
          setScreenShareEnabled: () => Promise.reject(new DOMException("Permission denied", "NotAllowedError"))
        }
      };
      window.dispatchEvent(new CustomEvent("huddle:stream-start", {
        detail: { roomId: arguments[0], quality: "1080p15" }
      }));
    JS

    wait_for_condition("the cancelled capture did not DELETE the stream") do
      page.evaluate_script("window.__streamDeleteSeen.length") > 0
    end
    wait_for_condition("the cancelled capture left the stream live") do
      Stream.find_by(room_id: room.id)&.ended_at.present?
    end

    assert_no_selector ".stage-live__badge"
  end

  test "viewers see the stream go live and end without reloading" do
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:kevin) ])

    using_session("Viewer") do
      @stream_sessions << "Viewer"
      sign_in "kevin@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
    end

    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    join_stage_without_media(room, users(:david))
    find("button[aria-label='Show stage']").click

    select "1080p15", from: "Stream quality"
    click_button "Go live"
    assert_selector ".stage-live__badge", text: "Live: David"

    using_session("Viewer") do
      assert_selector ".stage-live__badge", text: "Live: David", wait: 10
      assert_selector "#voice_rooms .stage-room .stage-live-dot__pip"

      find("button[aria-label='Show stage']").click
      assert_selector ".stage-panel__note--live", text: "Live: David"
      assert_no_selector "button", text: "Stop stream", visible: :visible
    end

    click_button "Stop stream"

    using_session("Viewer") do
      assert_no_selector ".stage-live__badge", wait: 10
      assert_no_selector "#voice_rooms .stage-room .stage-live-dot__pip"
    end

    assert_not_predicate Stream.find_by(room_id: room.id), :live?
  end

  test "a viewer watching a live stream sees it expanded with watchers and quality" do
    skip "Run with LIVEKIT_SYSTEM_TESTS=1 and a configured LiveKit server" unless livekit_enabled?
    room = create_stage_room(name: "Town Hall", members: [ users(:david), users(:kevin) ])

    sign_in "david@37signals.com"
    visit room_path(room)
    wait_for_cable_connection
    join_stage_and_confirm

    using_session("Viewer") do
      @stream_sessions << "Viewer"
      sign_in "kevin@37signals.com"
      visit room_path(room)
      wait_for_cable_connection
      join_stage_and_confirm
    end

    find("button[aria-label='Show stage']").click
    select "1080p15", from: "Stream quality"
    click_button "Go live"

    using_session("Viewer") do
      assert_selector "#channel-huddle.huddle--theater", wait: 20
      assert_selector ".huddle__screen--expanded video"
      assert_selector ".huddle__watching", text: "1 watching"

      quality = find("[data-huddle-target='streamQuality']", visible: :visible)
      assert_equal "auto", quality.value

      select "Low", from: "Stream quality"
      wait_for_condition("the Low choice did not pin the subscription") do
        stream_subscription_quality == 0
      end
      assert_equal "low", page.evaluate_script("window.localStorage.getItem('campfire.huddle.streamQuality')")

      select "High", from: "Stream quality"
      wait_for_condition("the High choice did not pin the subscription") do
        stream_subscription_quality == 2
      end

      select "Auto", from: "Stream quality"
      wait_for_condition("Auto did not restore adaptive streaming") do
        stream_subscription_quality.nil?
      end
      assert_equal "auto", page.evaluate_script("window.localStorage.getItem('campfire.huddle.streamQuality')")
    end

    click_button "Stop stream"

    using_session("Viewer") do
      assert_no_selector "#channel-huddle.huddle--theater", wait: 10
      assert_no_selector ".stage-live__badge", wait: 10
    end
  end

  private
    def livekit_enabled?
      ENV["LIVEKIT_SYSTEM_TESTS"] == "1"
    end

    def create_stage_room(name:, members:)
      Rooms::Stage.create_for({ name:, creator: members.first }, users: members).tap do |room|
        @stream_rooms << room
      end
    end

    # The non-LiveKit stand-in for joining the stage: a real grant so the
    # server accepts the Go live POST, plus a synthetic huddle:changed event
    # so the stage panel enables the control, mirroring the connected state
    # a real join would broadcast.
    def join_stage_without_media(room, user)
      HuddleGrant.issue!(
        session: user.sessions.create!(user_agent: "System Test"),
        membership: room.memberships.find_by!(user: user)
      )
      dispatch_huddle_changed(room_id: room.id, state: "connected")
    end

    def dispatch_huddle_changed(room_id:, state:)
      page.execute_script(<<~JS, room_id, state)
        window.dispatchEvent(new CustomEvent("huddle:changed", {
          detail: { roomId: arguments[0], state: arguments[1], sharing: [], expanded: false }
        }));
      JS
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

    def stream_subscription_quality
      page.evaluate_script(<<~JS)
        (() => {
          const controller = window.Stimulus
            .getControllerForElementAndIdentifier(document.getElementById("channel-huddle"), "huddle");
          for (const attachment of controller.attachments.values()) {
            if (attachment.kind === "screen" && !attachment.isLocal) {
              return attachment.publication.requestedMaxQuality ?? null;
            }
          }
          return "none";
        })()
      JS
    end

    def start_gateway
      gateway_log_path = Rails.root.join("tmp/livekit-gateway-streaming-test.log")
      @gateway_log = File.open(gateway_log_path, "w")
      environment = {
        "GATEWAY_CAMPFIRE_URL" => "http://127.0.0.1:#{CAMPFIRE_PORT}",
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

    def wait_for_condition(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
      assert true
    end
end
