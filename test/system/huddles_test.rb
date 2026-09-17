require "application_system_test_case"
require "socket"
require "timeout"
require "uri"

class HuddlesTest < ApplicationSystemTestCase
  self.use_transactional_tests = false

  CAMPFIRE_PORT = 3001
  GATEWAY_PORT = 7884

  # The gateway spawned below calls back into this fixture server, so the port
  # is fixed only for LiveKit-backed runs. Every other system test file loads
  # this class too, and a fixed port would make parallel workers collide.
  Capybara.server_port = CAMPFIRE_PORT if ENV["LIVEKIT_SYSTEM_TESTS"] == "1"

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ], options: { name: :huddle_chrome } do |options|
    options.add_argument "--use-fake-device-for-media-stream"
    options.add_argument "--use-fake-ui-for-media-stream"
    options.add_argument "--autoplay-policy=no-user-gesture-required"
  end

  setup do
    skip "Run with LIVEKIT_SYSTEM_TESTS=1 and a configured LiveKit server" unless ENV["LIVEKIT_SYSTEM_TESTS"] == "1"
    @original_livekit_url = ENV["LIVEKIT_URL"]
    gateway_url = ENV["LIVEKIT_SYSTEM_TEST_GATEWAY_URL"].presence
    ENV["LIVEKIT_URL"] = gateway_url || "ws://127.0.0.1:#{GATEWAY_PORT}"
    @forgery_protection = ActionController::Base.allow_forgery_protection
    assert Huddle.configured?, "Source the LiveKit environment before running huddle tests"
    @huddle_sessions = [ "default" ]
    @huddle_rooms = [ rooms(:designers), rooms(:david_and_jason) ]
    HuddleCleanup.delete_all
    HuddleGrant.delete_all
    @huddle_rooms.each do |room|
      Huddle::RoomService.new.delete_room(room_name: Huddle.room_name(room.id))
    end
    ActionController::Base.allow_forgery_protection = true
    start_gateway unless gateway_url
  end

  teardown do
    if ENV["LIVEKIT_SYSTEM_TESTS"] == "1"
      begin
        @huddle_sessions.each do |name|
          using_session(name) do
            if page.has_css?("#channel-huddle:not([hidden])", wait: 0)
              find("[data-action='huddle#leave']").click
              assert_no_selector "#channel-huddle:not([hidden])"
            end
          end
        end
      ensure
        ActionController::Base.allow_forgery_protection = @forgery_protection
        begin
          stop_gateway
        ensure
          begin
            @huddle_rooms.each do |room|
              Huddle::RoomService.new.delete_room(room_name: Huddle.room_name(room.id))
            end
          ensure
            begin
              HuddleCleanup.delete_all
              HuddleGrant.delete_all
            ensure
              ENV["LIVEKIT_URL"] = @original_livekit_url
            end
          end
        end
      end
    end
  end

  test "two users exchange audio and a screen while navigating and muting" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
    original_connection_count = page.evaluate_script("window.huddleTestPeerConnections.length")

    click_button "Share screen"
    assert_button "Stop sharing"
    page.save_screenshot(Rails.root.join("tmp/screenshots/huddle-connected.png"))
    using_session("Kevin") do
      assert_selector ".huddle__participant", count: 2
      assert_media_received "audio"
      assert_selector ".huddle__screen video"
      wait_for_condition("the remote screen did not decode video") do
        page.evaluate_script("Array.from(document.querySelectorAll('.huddle__screen video')).some(video => video.videoWidth > 0 && video.readyState >= 2)")
      end
      assert_media_received "video"
    end

    # Follow the actual sidebar link: a full visit would drop WebRTC connections.
    within("#sidebar") { click_link "HQ", exact: true }
    assert_selector ".room--current", text: "HQ"
    assert_selector "#channel-huddle[data-state='connected']"
    assert_selector "#huddle-room-name", text: "Designers"
    assert_equal original_connection_count, page.evaluate_script("window.huddleTestPeerConnections.length")
    assert_media_received "audio"

    click_button "Mute", exact: true
    assert_button "Unmute", exact: true
    using_session("Kevin") { assert_selector ".huddle__participant", text: /JZ.*Muted/m }
    click_button "Unmute", exact: true
    assert_button "Mute", exact: true

    click_button "Stop sharing"
    assert_button "Share screen"
    using_session("Kevin") { assert_no_selector ".huddle__screen video" }

    click_button "Leave", exact: true
    assert_no_selector "#channel-huddle:not([hidden])"
    assert_no_selector "#channel-huddle audio", visible: :all
    wait_for_condition("local media was not stopped on leave") do
      page.evaluate_script("window.huddleTestLocalTracks.every(track => track.readyState === 'ended')")
    end
    using_session("Kevin") { assert_selector ".huddle__participant", count: 1 }
  end

  test "two users exchange camera video while navigating, muting, toggling, and leaving" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
    assert_selector "[data-huddle-target='camera'][aria-pressed='false']", text: "Camera off"
    assert_no_selector ".huddle__camera video"

    click_button "Camera off", exact: true
    assert_selector "[data-huddle-target='camera'][aria-pressed='true']", text: "Camera on"
    assert_selector ".huddle__camera--local video"
    assert_selector ".huddle__camera figcaption", text: "JZ (you)"
    wait_for_condition("the local camera preview did not decode video") do
      local_camera_decoding?
    end

    using_session("Kevin") do
      assert_selector ".huddle__camera:not(.huddle__camera--local) video"
      assert_selector ".huddle__camera figcaption", text: "JZ"
      wait_for_condition("the remote camera did not decode video") do
        remote_camera_decoding?
      end
      assert_media_received "video"

      click_button "Camera off", exact: true
      assert_selector "[data-huddle-target='camera'][aria-pressed='true']", text: "Camera on"
    end

    assert_selector ".huddle__camera", count: 2
    wait_for_condition("the remote camera did not decode video") do
      remote_camera_decoding?
    end
    assert_media_received "video"

    click_button "Mute", exact: true
    assert_button "Unmute", exact: true
    assert_selector ".huddle__camera", count: 2
    wait_for_condition("muting stopped the remote camera") do
      remote_camera_decoding?
    end
    click_button "Unmute", exact: true
    assert_button "Mute", exact: true

    click_button "Share screen"
    assert_button "Stop sharing"
    assert_selector ".huddle__screen video"
    assert_selector ".huddle__camera", count: 2
    using_session("Kevin") do
      assert_selector ".huddle__screen video"
      find("[data-huddle-screen-expand]").click
      assert_selector "#channel-huddle.huddle--theater"
      assert_selector ".huddle__camera", count: 2
      assert_camera_thumbnails_do_not_cover_expanded_screen
      find("body").send_keys :escape
      assert_no_selector "#channel-huddle.huddle--theater"
    end
    click_button "Stop sharing"
    assert_button "Share screen"

    # Follow the actual sidebar link: a full visit would drop WebRTC connections.
    original_connection_count = page.evaluate_script("window.huddleTestPeerConnections.length")
    within("#sidebar") { click_link "HQ", exact: true }
    assert_selector ".room--current", text: "HQ"
    assert_selector "#channel-huddle[data-state='connected']"
    assert_selector ".huddle__camera", count: 2
    assert_equal original_connection_count, page.evaluate_script("window.huddleTestPeerConnections.length")
    wait_for_condition("the remote camera did not survive navigation") do
      remote_camera_decoding?
    end

    click_button "Camera on", exact: true
    assert_selector "[data-huddle-target='camera'][aria-pressed='false']", text: "Camera off"
    assert_selector ".huddle__camera", count: 1
    using_session("Kevin") { assert_selector ".huddle__camera", count: 1 }

    using_session("Kevin") do
      click_button "Leave", exact: true
      assert_no_selector "#channel-huddle:not([hidden])"
      wait_for_condition("local camera was not stopped on leave") do
        page.evaluate_script("window.huddleTestLocalTracks.every(track => track.readyState === 'ended')")
      end
    end
    assert_selector ".huddle__participant", count: 1
    assert_no_selector ".huddle__camera video"

    # Joining stays audio-only: a rejoin never restores the previous camera state.
    within("#sidebar") { click_link "Designers", exact: true }
    click_button "Leave", exact: true
    assert_no_selector "#channel-huddle:not([hidden])"
    join_huddle_and_confirm
    assert_selector "[data-huddle-target='camera'][aria-pressed='false']", text: "Camera off"
    assert_no_selector ".huddle__camera video"
  end

  test "a camera that fails to start keeps the huddle connected and stays retryable" do
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    open_huddle_as "jz@37signals.com"
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"

    page.execute_script <<~JS
      window.huddleTestGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = (constraints) => {
        if (constraints && constraints.video) {
          return Promise.reject(new DOMException('Test permission denial', 'NotAllowedError'));
        }
        return window.huddleTestGetUserMedia(constraints);
      };
    JS

    click_button "Camera off", exact: true

    assert_selector "#channel-huddle[data-state='connected']"
    assert_selector "[data-huddle-target='notice']", text: /Camera wasn’t started/
    assert_selector "[data-huddle-target='camera']:not([disabled])", text: "Camera off"
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
    using_session("Kevin") do
      assert_selector ".huddle__participant", count: 2
      assert_media_received "audio"
      assert_no_selector ".huddle__camera video"
    end

    page.execute_script "navigator.mediaDevices.getUserMedia = window.huddleTestGetUserMedia"
    click_button "Camera off", exact: true
    assert_selector "[data-huddle-target='camera'][aria-pressed='true']", text: "Camera on"
    assert_no_selector "[data-huddle-target='notice']:not([hidden])"
    assert_selector ".huddle__camera--local video"
    using_session("Kevin") do
      assert_selector ".huddle__camera video"
      wait_for_condition("the retried camera did not decode video") do
        remote_camera_decoding?
      end
      assert_media_received "video"
    end
  end

  test "two direct message participants exchange audio and screen while navigating and reconnecting" do
    direct_room = rooms(:david_and_jason)
    open_huddle_as "david@37signals.com", room: direct_room
    using_session("Jason") { open_huddle_as "jason@37signals.com", room: direct_room, session_name: "Jason" }

    assert_selector ".room-header__kind", text: /Direct message/i
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
    original_connection_count = page.evaluate_script("window.huddleTestPeerConnections.length")

    click_button "Share screen"
    assert_button "Stop sharing"
    using_session("Jason") do
      assert_selector ".huddle__participant", count: 2
      assert_media_received "audio"
      assert_selector ".huddle__screen video"
      wait_for_condition("the direct-message screen did not decode video") do
        page.evaluate_script("Array.from(document.querySelectorAll('.huddle__screen video')).some(video => video.videoWidth > 0 && video.readyState >= 2)")
      end
      assert_media_received "video"
    end

    within("#sidebar") { click_link "HQ", exact: true }
    assert_selector ".room--current", text: "HQ"
    assert_selector "#channel-huddle[data-state='connected']"
    assert_equal original_connection_count, page.evaluate_script("window.huddleTestPeerConnections.length")

    within("#sidebar") { find("##{dom_id(direct_room, :list)}").click }
    assert_selector ".room-header__kind", text: /Direct message/i
    assert_selector ".room-header__name", text: "Jason"
    assert_selector "#channel-huddle[data-state='connected']"
    assert_media_received "audio"

    socket_count = signal_socket_urls.length
    peer_connection_count = page.evaluate_script("window.huddleTestPeerConnections.length")
    force_full_reconnect
    wait_for_condition("the direct-message huddle did not reconnect") do
      signal_socket_urls.length > socket_count
    end
    assert_selector "#channel-huddle[data-state='connected']", wait: 20
    assert_new_active_media_received "audio", after: peer_connection_count
    using_session("Jason") do
      assert_selector "#channel-huddle[data-state='connected']"
      assert_selector ".huddle__participant", count: 2
      assert_media_received "audio"
    end

    click_button "Leave", exact: true
    assert_no_selector "#channel-huddle:not([hidden])"
    assert_no_selector "#channel-huddle audio", visible: :all
    using_session("Jason") { assert_selector ".huddle__participant", count: 1 }
  end

  test "a viewer enlarges a shared screen into theater mode and leaves it with escape" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    click_button "Share screen"
    assert_button "Stop sharing"

    using_session("Kevin") do
      assert_selector ".huddle__screen video"
      assert_selector ".huddle-share-indicator", text: /is sharing/
      assert_selector "[data-huddle-target='sharing']", text: /is sharing a screen/
      panel_width = screen_video_width
      assert_operator panel_width, :>, 0

      find("[data-huddle-screen-expand]").click

      assert_selector "#channel-huddle.huddle--theater"
      assert_selector ".huddle__screen--expanded video"
      assert_selector "[data-huddle-screen-expand][aria-expanded='true']", text: "Collapse"
      wait_for_condition("the expanded screen did not grow") { screen_video_width > panel_width * 1.5 }
      wait_for_condition("the expanded screen stopped decoding video") do
        page.evaluate_script("(() => { const video = document.querySelector('.huddle__screen--expanded video'); return Boolean(video && video.videoWidth > 0 && video.readyState >= 2) })()")
      end
      assert_media_received "video"

      find("body").send_keys :escape

      assert_no_selector "#channel-huddle.huddle--theater"
      assert_selector "[data-huddle-screen-expand][aria-expanded='false']", text: "Expand"
      assert_equal "Expand", page.evaluate_script("document.activeElement.textContent")
    end
  end

  test "the room header shares-screen button opens the shared screen" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    using_session("Kevin") { assert_no_selector ".huddle-share-indicator" }

    click_button "Share screen"
    assert_button "Stop sharing"

    using_session("Kevin") do
      assert_selector ".huddle-share-indicator", text: "JZ is sharing"
      find(".huddle-share-indicator").click
      assert_selector "#channel-huddle.huddle--theater"
      assert_selector ".huddle__screen--expanded video"
    end

    click_button "Stop sharing"
    using_session("Kevin") do
      assert_no_selector ".huddle-share-indicator"
      assert_no_selector "#channel-huddle.huddle--theater"
    end
  end

  test "the full screen control asks for the figure and falls back to the video element" do
    open_huddle_as "jz@37signals.com"
    stub_fullscreen_requests
    click_button "Share screen"
    assert_button "Stop sharing"
    assert_selector ".huddle__screen video"

    find("[data-huddle-screen-fullscreen]").click

    wait_for_condition("no element was asked for full screen") { fullscreen_requests.any? }
    assert_equal [ "FIGURE", "VIDEO" ], fullscreen_requests,
      "the figure keeps the caption, so it is tried before the bare video element"
    # A browser that refuses full screen still has to enlarge the share.
    assert_selector "#channel-huddle.huddle--theater"
    assert_selector "[data-huddle-target='status']", text: /Full screen isn’t available/
  end

  test "noise suppression runs on the microphone, can be switched off, and is remembered" do
    open_huddle_as "jz@37signals.com"

    assert_selector "[data-huddle-target='noise'][aria-pressed='true']", text: "Noise suppression on"
    wait_for_condition("the RNNoise processor never attached to the microphone") do
      microphone_processor_name == "campfire-rnnoise"
    end

    click_button "Noise suppression on"

    assert_selector "[data-huddle-target='noise'][aria-pressed='false']", text: "Noise suppression off"
    wait_for_condition("the RNNoise processor was not removed") { microphone_processor_name.nil? }
    assert_equal "off", page.evaluate_script("window.localStorage.getItem('campfire.huddle.noiseSuppression')")

    click_button "Leave", exact: true
    join_huddle_and_confirm

    assert_selector "[data-huddle-target='noise'][aria-pressed='false']", text: "Noise suppression off"
    assert_nil microphone_processor_name
  end

  test "noise suppression can be switched back on without leaving the huddle" do
    open_huddle_as "jz@37signals.com"

    wait_for_condition("the RNNoise processor never attached to the microphone") do
      microphone_processor_name == "campfire-rnnoise"
    end

    click_button "Noise suppression on"
    assert_selector "[data-huddle-target='noise'][aria-pressed='false']", text: "Noise suppression off"
    wait_for_condition("the RNNoise processor was not removed") { microphone_processor_name.nil? }

    click_button "Noise suppression off"

    assert_selector "[data-huddle-target='noise'][aria-pressed='true']", text: "Noise suppression on"
    wait_for_condition("the RNNoise processor did not come back") do
      microphone_processor_name == "campfire-rnnoise"
    end
    assert_equal "on", page.evaluate_script("window.localStorage.getItem('campfire.huddle.noiseSuppression')")
  end

  test "muting and unmuting keeps the noise suppressor on the microphone" do
    open_huddle_as "jz@37signals.com"

    wait_for_condition("the RNNoise processor never attached to the microphone") do
      microphone_processor_name == "campfire-rnnoise"
    end

    click_button "Mute"
    assert_button "Unmute"
    assert_selector "#channel-huddle.huddle--muted"

    click_button "Unmute"
    assert_button "Mute"

    # Muting disables the published track rather than replacing it, so the
    # processor has to survive the round trip.
    wait_for_condition("the RNNoise processor was lost across mute and unmute") do
      microphone_processor_name == "campfire-rnnoise"
    end
    assert_selector "[data-huddle-target='noise'][aria-pressed='true']", text: "Noise suppression on"
  end

  test "a second shared screen stays reachable while the first one is expanded" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    click_button "Share screen"
    assert_button "Stop sharing"

    using_session("Kevin") do
      assert_selector ".huddle__screen video"
      click_button "Share screen"
      assert_button "Stop sharing"

      assert_selector ".huddle__screen", count: 2
      assert_selector "[data-huddle-target='sharing']", text: "2 people are sharing a screen"

      click_button "View"
      assert_selector "#channel-huddle.huddle--theater"
      first_expanded = expanded_screen_label
      assert first_expanded.present?

      # The screen that is not expanded stays on as a thumbnail, so its own
      # control is still there to be used.
      assert_selector "[data-huddle-screen-expand][aria-expanded='false']", count: 1

      click_button "Next screen"

      wait_for_condition("the banner did not move to the other shared screen") do
        expanded_screen_label.present? && expanded_screen_label != first_expanded
      end
      assert_selector "#channel-huddle.huddle--theater"
      assert_selector "[data-huddle-screen-expand][aria-expanded='true']", count: 1
    end
  end

  test "a noise suppressor that fails to load still connects the huddle and stays retryable" do
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    prepare_browser
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
    break_noise_suppression

    join_huddle_and_confirm
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
    assert_selector "[data-huddle-target='status']", text: /Noise suppression couldn’t start/
    assert_nil microphone_processor_name
    using_session("Kevin") { assert_media_received "audio" }

    # A download that failed once may well succeed next time, so the control has
    # to stay usable and the preference must not record the failure.
    assert_selector "[data-huddle-target='noise']:not([disabled])", text: "Noise suppression off"
    # Nothing is stored, so the default of "on" is what a rejoin reads back.
    assert_nil page.evaluate_script("window.localStorage.getItem('campfire.huddle.noiseSuppression')")
  end

  test "a browser that cannot run the noise suppressor turns the control off for good" do
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    prepare_browser
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
    break_noise_suppression error: "NotSupportedError"

    join_huddle_and_confirm
    assert_media_received "audio"
    assert_selector "[data-huddle-target='noise'][disabled]", text: "Noise suppression unavailable"
    assert_nil microphone_processor_name
  end

  test "denied microphone stops the device check before anything is published and can be retried" do
    prepare_browser
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
    stub_microphone_permission "prompt"
    page.execute_script <<~JS
      window.huddleTestGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('Test permission denial', 'NotAllowedError'));
    JS
    credentials_before = huddle_credentials_count

    click_button "Join huddle"

    # With fresh permissions the denial lands in the device check, before any
    # credentials are requested, so no ghost participant can exist server-side.
    assert_selector "#channel-huddle[data-state='prejoin']"
    assert_selector "[data-huddle-target='checkError']", text: /Microphone access was denied/
    assert_equal credentials_before, huddle_credentials_count

    page.execute_script "navigator.mediaDevices.getUserMedia = window.huddleTestGetUserMedia"
    restore_microphone_permission
    click_button "Try again"
    assert_selector "[data-huddle-target='checkJoin']:not([disabled])", wait: 20
    find("[data-huddle-target='checkJoin']").click
    assert_selector "#channel-huddle[data-state='connected']"
    assert_selector ".huddle__participant", count: 1

    using_session("Kevin") do
      open_huddle_as "kevin@37signals.com"
      assert_selector ".huddle__participant", count: 2
      assert_media_received "audio"
    end
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
  end

  test "device pickers list the fake devices and switching keeps media flowing" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    click_button "Check devices"
    assert_selector "[data-huddle-target='devicesBlock']:not([hidden])"

    microphone_labels = device_select_labels("microphoneSelect")
    camera_labels = device_select_labels("cameraSelect")
    speaker_labels = device_select_labels("speakerSelect")
    assert_not_empty microphone_labels
    assert_not_empty camera_labels
    assert_not_empty speaker_labels
    # Permissions are granted by now, so these are real device names rather
    # than the numbered placeholders used before access.
    assert microphone_labels.none? { |label| label.start_with?("Microphone ") }
    assert camera_labels.none? { |label| label.start_with?("Camera ") }
    assert speaker_labels.none? { |label| label.start_with?("Speaker ") }
    assert_selector "[data-huddle-target='speakerRow']:not([hidden])"

    # The fake backend offers several microphones and speakers but one camera.
    other_microphone = device_select_other_option("microphoneSelect")
    assert other_microphone, "expected the fake backend to offer at least two microphones"
    select other_microphone["label"], from: "Microphone"
    wait_for_condition("the microphone switch was not remembered") do
      stored_device_preferences["audioinput"] == other_microphone["value"]
    end
    using_session("Kevin") { assert_media_received "audio" }
    wait_for_condition("the meter never came back after the microphone switch") do
      microphone_meter_level > 0
    end

    other_speaker = device_select_other_option("speakerSelect")
    assert other_speaker, "expected the fake backend to offer at least two speakers"
    select other_speaker["label"], from: "Speaker"
    wait_for_condition("the speaker switch was not remembered") do
      stored_device_preferences["audiooutput"] == other_speaker["value"]
    end
    assert_media_received "audio"

    # One fake camera means no second option to click; driving the handler with
    # the listed camera still restarts the capture on the real switch path.
    click_button "Camera off", exact: true
    using_session("Kevin") do
      assert_selector ".huddle__camera video"
      wait_for_condition("the camera did not decode video") { remote_camera_decoding? }
    end
    switch_device_select("cameraSelect")
    wait_for_condition("the camera switch was not remembered") do
      stored_device_preferences["videoinput"] == device_select_value("cameraSelect")
    end
    using_session("Kevin") do
      wait_for_condition("the camera switch stopped the video") { remote_camera_decoding? }
    end

    # A speaker that vanished mid-call fails as a status line, not a disconnect.
    select_missing_device_option("speakerSelect")
    assert_selector "[data-huddle-target='status']", text: /speaker could not be switched/
    assert_media_received "audio"

    click_button "Done"
    assert_no_selector "[data-huddle-target='devicesBlock']:not([hidden])"
  end

  test "the microphone meter follows the fake microphone and rests while muted" do
    open_huddle_as "jz@37signals.com"

    assert_selector "[data-huddle-target='meter']:not([hidden])"
    wait_for_condition("the microphone meter never rose") { microphone_meter_level > 0 }

    click_button "Mute", exact: true
    assert_no_selector "[data-huddle-target='meter']:not([hidden])"
    assert_equal 0, microphone_meter_level
    assert_not microphone_meter_running,
      "the meter kept polling while muted"

    click_button "Unmute", exact: true
    assert_selector "[data-huddle-target='meter']:not([hidden])"
    wait_for_condition("the microphone meter never came back after unmuting") do
      microphone_meter_level > 0
    end

    page.execute_script <<~JS
      window.huddleTestMeterContext = window.Stimulus
        .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle')
        .microphoneMeter.analyser.analyser.context;
    JS
    assert_equal "running", page.evaluate_script("window.huddleTestMeterContext.state")

    click_button "Leave", exact: true
    assert_no_selector "#channel-huddle:not([hidden])"
    assert_not microphone_meter_running,
      "the meter kept polling after leaving"
    assert_equal "closed", page.evaluate_script("window.huddleTestMeterContext.state"),
      "leaving the huddle left the meter AudioContext alive"
  end

  test "the device check appears for a first join and is skipped once permissions were granted" do
    prepare_browser
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
    stub_microphone_permission "prompt"
    credentials_before = huddle_credentials_count

    click_button "Join huddle"

    assert_selector "#channel-huddle[data-state='prejoin']"
    assert_selector "[data-huddle-target='devicesBlock']", text: "Check your devices"
    assert_selector "[data-huddle-target='microphoneSelect'] option", minimum: 1
    assert_selector "[data-huddle-target='cameraSelect'] option", minimum: 1
    # Nothing is requested or published before the user confirms.
    assert_equal credentials_before, huddle_credentials_count

    assert_selector "[data-huddle-target='checkJoin']:not([disabled])", wait: 20
    wait_for_condition("the pre-join meter never rose") { prejoin_meter_level > 0 }
    wait_for_condition("the camera preview did not show video") { camera_preview_live? }
    tracks_before_join = page.evaluate_script("window.huddleTestLocalTracks.length")
    find("[data-huddle-target='checkJoin']").click

    assert_selector "#channel-huddle[data-state='connected']", wait: 20
    assert_selector ".huddle__participant", count: 1
    wait_for_condition("the preview tracks were not stopped on join") do
      page.evaluate_script("window.huddleTestLocalTracks.slice(0, #{tracks_before_join}).every(track => track.readyState === 'ended')")
    end

    click_button "Leave", exact: true
    assert_no_selector "#channel-huddle:not([hidden])"

    # The check needs no confirmation the second time: reaching connected
    # without touching it proves it was skipped, since it never advances alone.
    restore_microphone_permission
    click_button "Join huddle"
    assert_selector "#channel-huddle[data-state='connected']", wait: 20

    click_button "Check devices"
    assert_selector "[data-huddle-target='devicesBlock']:not([hidden])"
    assert_selector "[data-huddle-target='microphoneSelect'] option", minimum: 1
    click_button "Done"
    assert_no_selector "[data-huddle-target='devicesBlock']:not([hidden])"
  end

  test "the connection indicator renders and the details panel shows sampled statistics" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }

    assert_selector "[data-huddle-target='connection']:not([hidden])"
    quality = page.evaluate_script("document.querySelector(\"[data-huddle-target='connection']\").dataset.quality")
    assert_includes %w[good fair poor], quality

    # Statistics are sampled only while the panel is open.
    assert_not connection_sampling?, "connection statistics were sampled before the panel opened"
    find("[data-huddle-target='connection']").click
    assert_selector "[data-huddle-target='connectionDetails']:not([hidden])"
    assert connection_sampling?, "connection statistics were not sampled while the panel was open"

    wait_for_condition("round-trip time was never sampled") { connection_stat("statRtt") != "–" }
    assert_match(/\A[\d.]+ ms\z/, connection_stat("statRtt"))
    assert_match(/\A[\d.]+%\z/, connection_stat("statLoss"))
    assert_match(/\A[\d.]+ ms\z/, connection_stat("statJitter"))
    # Bitrates need two samples, so they trail the first paint by one interval.
    wait_for_condition("bitrates were never sampled") do
      connection_stat("statRx") != "–" && connection_stat("statSent") != "–"
    end
    assert_match(/\A[\d.]+ (kbps|Mbps)\z/, connection_stat("statRx"))
    assert_match(/\A[\d.]+ (kbps|Mbps)\z/, connection_stat("statSent"))
    assert_equal force_relay? ? "Relayed (TURN)" : "Direct", connection_stat("statTransport")

    find("[data-huddle-target='connection']").click
    assert_no_selector "[data-huddle-target='connectionDetails']:not([hidden])"
    assert_not connection_sampling?, "connection statistics kept sampling after the panel closed"
  end

  test "server removal disconnects only the targeted participant and stops their media" do
    open_huddle_as "jz@37signals.com"
    identity = captured_credentials.fetch("identity")
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"

    # Exercise the real server API without relying on the client's access poll
    # or a Campfire navigation to end the connection.
    Huddle::RoomService.new.remove_participant(room_name: Huddle.room_name(rooms(:designers).id), identity: identity)

    assert_selector "#channel-huddle[data-state='failed']", wait: 10
    assert_no_selector "#channel-huddle audio", visible: :all
    wait_for_condition("revoked participant's local media was not stopped") do
      page.evaluate_script("window.huddleTestLocalTracks.every(track => track.readyState === 'ended')")
    end
    using_session("Kevin") do
      assert_selector "#channel-huddle[data-state='connected']"
      assert_selector ".huddle__participant", count: 1
    end
  end

  test "the SDK reconnects through the gateway with LiveKit's refreshed token" do
    open_huddle_as "jz@37signals.com"
    credentials = captured_credentials
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"

    original_token = credentials.fetch("token")
    refreshed_token = wait_for_refreshed_token(original_token)
    original_claims = decode_token(original_token)
    refreshed_claims = decode_token(refreshed_token)

    assert original_token != refreshed_token, "LiveKit did not replace the original token"
    assert_equal credentials.fetch("identity"), original_claims.fetch("sub")
    assert_equal original_claims.fetch("sub"), refreshed_claims.fetch("sub")
    assert_equal original_claims.dig("video", "room"), refreshed_claims.dig("video", "room")

    socket_count = signal_socket_urls.length
    peer_connection_count = page.evaluate_script("window.huddleTestPeerConnections.length")
    force_full_reconnect

    wait_for_condition("the SDK did not reconnect with LiveKit's refreshed token") do
      signal_socket_urls.drop(socket_count).any? { |url| signal_token(url) == refreshed_token }
    end
    assert_selector "#channel-huddle[data-state='connected']", wait: 20
    assert_new_active_media_received "audio", after: peer_connection_count
    using_session("Kevin") do
      assert_selector "#channel-huddle[data-state='connected']"
      assert_selector ".huddle__participant", count: 2
    end
  end

  test "membership revocation rejects original and refreshed tokens even after membership is restored" do
    open_huddle_as "jz@37signals.com"
    credentials = captured_credentials
    original_signal_url = signal_socket_urls.first
    original_token = credentials.fetch("token")
    refreshed_token = wait_for_refreshed_token(original_token)
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"

    with_rescuable_server_exceptions do
      rooms(:designers).memberships.revoke_from(users(:jz))

      assert_huddle_access_ended
      using_session("Kevin") { assert_remaining_participant_connected }
      assert_tokens_unexpired original_token, refreshed_token
      assert_signal_token_rejected original_signal_url, original_token
      assert_signal_token_rejected original_signal_url, refreshed_token

      rooms(:designers).memberships.grant_to(users(:jz))
      retry_huddle_and_confirm
      replacement_credentials = captured_credentials(1)

      assert_not_equal credentials.fetch("grant_id"), replacement_credentials.fetch("grant_id")
      assert_not_equal credentials.fetch("identity"), replacement_credentials.fetch("identity")

      # Current room membership is valid again. These still have to fail because
      # they belong to the revoked grant rather than the new authorization.
      assert_tokens_unexpired original_token, refreshed_token
      assert_signal_token_rejected original_signal_url, original_token
      assert_signal_token_rejected original_signal_url, refreshed_token
      using_session("Kevin") do
        assert_selector ".huddle__participant", count: 2
        assert_media_received "audio"
      end
    end
  end

  test "session revocation rejects both tokens and leaves the other participant connected" do
    open_huddle_as "jz@37signals.com"
    credentials = captured_credentials
    original_signal_url = signal_socket_urls.first
    original_token = credentials.fetch("token")
    refreshed_token = wait_for_refreshed_token(original_token)
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"

    HuddleGrant.find(credentials.fetch("grant_id")).session.destroy!

    assert_huddle_access_ended
    using_session("Kevin") { assert_remaining_participant_connected }
    assert_tokens_unexpired original_token, refreshed_token
    assert_signal_token_rejected original_signal_url, original_token
    assert_signal_token_rejected original_signal_url, refreshed_token
    using_session("Kevin") { assert_remaining_participant_connected }
  end

  test "server enforcement removes a revoked participant that ignores browser access checks" do
    open_huddle_as "jz@37signals.com"
    credentials = captured_credentials
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
    received_before_revocation = inbound_rtp_bytes("audio")
    assert_operator received_before_revocation, :>, 0
    ignore_huddle_access_checks

    HuddleGrant.find(credentials.fetch("grant_id")).revoke!

    using_session("Kevin") do
      assert_selector "#channel-huddle[data-state='connected']"
      assert_selector ".huddle__participant", count: 1, wait: 20
    end
    assert_inbound_media_stopped "audio"
  end

  private
    def open_huddle_as(email, room: rooms(:designers), session_name: nil)
      @huddle_sessions << session_name if session_name && !@huddle_sessions.include?(session_name)
      prepare_browser
      sign_in email
      join_room room
      join_huddle_and_confirm
    end

    # The first join in a browser stops at the device check; later joins skip
    # it. Either way the huddle ends up connected.
    def join_huddle_and_confirm
      click_button "Join huddle"
      confirm_prejoin_if_present
      assert_selector "#channel-huddle[data-state='connected']", wait: 20
      assert_button "Mute", exact: true
    end

    def retry_huddle_and_confirm
      click_button "Try again"
      confirm_prejoin_if_present
      assert_selector "#channel-huddle[data-state='connected']", wait: 20
      assert_button "Mute", exact: true
    end

    def confirm_prejoin_if_present
      wait_for_condition("the huddle did not start joining") do
        %w[prejoin connecting connected].any? do |state|
          page.has_css?("#channel-huddle[data-state='#{state}']", wait: 0)
        end
      end
      return unless page.has_css?("#channel-huddle[data-state='prejoin']", wait: 0)

      # The preview needs a moment to acquire the fake devices before Join enables.
      assert_selector "[data-huddle-target='checkJoin']:not([disabled])", wait: 20
      find("[data-huddle-target='checkJoin']").click
    end

    def prepare_browser
      source = <<~'JS'
        (() => {
        if (window.huddleTestInstrumentationInstalled) return;
        window.huddleTestInstrumentationInstalled = true;
        const forceRelay = __HUDDLE_TEST_FORCE_RELAY__;

        window.huddleTestPeerConnections = [];
        window.huddleTestLocalTracks = [];
        window.huddleTestCredentials = [];
        window.huddleTestWebSocketUrls = [];

        const nativeFetch = window.fetch.bind(window);
        window.fetch = async (...args) => {
          const response = await nativeFetch(...args);
          try {
            const input = args[0];
            const options = args[1] || {};
            const url = typeof input === 'string' ? input : input.url;
            const method = (options.method || input.method || 'GET').toUpperCase();
            if (method === 'POST' && new URL(url, window.location.origin).pathname.match(/^\/rooms\/\d+\/huddle$/)) {
              response.clone().json().then(body => window.huddleTestCredentials.push(body));
            }
          } catch (_) {}
          return response;
        };

        const NativeWebSocket = window.WebSocket;
        window.WebSocket = class extends NativeWebSocket {
          constructor(...args) {
            super(...args);
            window.huddleTestWebSocketUrls.push(String(args[0]));
          }
        };

        const NativePeerConnection = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends NativePeerConnection {
          constructor(...args) {
            if (forceRelay) {
              args[0] = { ...(args[0] || {}), iceTransportPolicy: 'relay' };
            }
            super(...args);
            window.huddleTestPeerConnections.push(this);
          }

          setConfiguration(configuration) {
            const nextConfiguration = forceRelay
              ? { ...(configuration || {}), iceTransportPolicy: 'relay' }
              : configuration;
            super.setConfiguration(nextConfiguration);
          }
        };
        const nativeGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
        navigator.mediaDevices.getUserMedia = async (...args) => {
          const stream = await nativeGetUserMedia(...args);
          window.huddleTestLocalTracks.push(...stream.getTracks());
          return stream;
        };
        // Synthetic browser-generated screen content keeps personal desktop data
        // out of tests; LiveKit's real publish, transport and decode paths run.
        navigator.mediaDevices.getDisplayMedia = async () => {
          const canvas = document.createElement('canvas');
          canvas.width = 640;
          canvas.height = 360;
          const context = canvas.getContext('2d');
          let frame = 0;
          const draw = () => {
            context.fillStyle = frame++ % 2 ? '#164e63' : '#0f766e';
            context.fillRect(0, 0, 640, 360);
            context.fillStyle = 'white';
            context.font = '32px sans-serif';
            context.fillText('Campfire screen-share test', 40, 180);
          };
          draw();
          const stream = canvas.captureStream(10);
          const timer = setInterval(draw, 100);
          stream.getVideoTracks()[0].addEventListener('ended', () => clearInterval(timer));
          window.huddleTestLocalTracks.push(...stream.getTracks());
          return stream;
        };
        })();
      JS
      source = source.sub("__HUDDLE_TEST_FORCE_RELAY__", force_relay?.to_s)
      page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source:)
    end

    def screen_video_width
      page.evaluate_script("document.querySelector('.huddle__screen video')?.clientWidth || 0")
    end

    def local_camera_decoding?
      page.evaluate_script("Array.from(document.querySelectorAll('.huddle__camera--local video')).some(video => video.videoWidth > 0 && video.readyState >= 2)")
    end

    def remote_camera_decoding?
      page.evaluate_script("Array.from(document.querySelectorAll('.huddle__camera:not(.huddle__camera--local) video')).some(video => video.videoWidth > 0 && video.readyState >= 2)")
    end

    def assert_camera_thumbnails_do_not_cover_expanded_screen
      overlap = page.evaluate_script(<<~JS)
        (() => {
          const screen = document.querySelector('.huddle__screen--expanded video');
          if (!screen) return 'missing expanded screen';
          const box = screen.getBoundingClientRect();
          const tiles = Array.from(document.querySelectorAll('.huddle__camera'));
          if (!tiles.length) return 'missing camera tiles';
          return tiles.some(tile => {
            const rect = tile.getBoundingClientRect();
            return rect.left < box.right && rect.right > box.left && rect.top < box.bottom && rect.bottom > box.top;
          }) ? 'overlap' : 'none';
        })()
      JS
      assert_equal "none", overlap
    end

    # Headless Chrome refuses real full screen, and a browser prompt would stall
    # the suite, so the request itself is what gets recorded here.
    def stub_fullscreen_requests
      page.execute_script <<~JS
        window.huddleTestFullscreenRequests = [];
        Element.prototype.requestFullscreen = function () {
          window.huddleTestFullscreenRequests.push(this.tagName);
          return Promise.reject(new DOMException('Test full screen refusal', 'NotAllowedError'));
        };
      JS
    end

    def fullscreen_requests
      page.evaluate_script("window.huddleTestFullscreenRequests || []")
    end

    def expanded_screen_label
      page.evaluate_script(<<~JS)
        document.querySelector("[data-huddle-screen-expand][aria-expanded='true']")?.getAttribute("aria-label") ?? null
      JS
    end

    def microphone_processor_name
      page.evaluate_script(<<~JS)
        window.Stimulus
          .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle')
          ?.room?.localParticipant?.getTrackPublication('microphone')?.audioTrack?.getProcessor()?.name ?? null
      JS
    end

    def device_select_labels(target)
      page.evaluate_script(<<~JS, target)
        Array.from(document.querySelector(`[data-huddle-target='${arguments[0]}']`).options).map(option => option.text)
      JS
    end

    def stored_device_preferences
      JSON.parse(page.evaluate_script("window.localStorage.getItem('campfire.huddle.devices')") || "{}")
    end

    def device_select_options(target)
      page.evaluate_script("Array.from(document.querySelector(\"[data-huddle-target='#{target}']\").options).map(option => ({ value: option.value, label: option.text }))")
    end

    def device_select_value(target)
      page.evaluate_script("document.querySelector(\"[data-huddle-target='#{target}']\").value")
    end

    def device_select_other_option(target)
      options = device_select_options(target)
      current = device_select_value(target)
      options.find { |option| option["value"] != current }
    end

    # Drives the change handler with the current selection. The fake backend
    # offers a single camera, so its switch path is exercised this way; the
    # switch still restarts the capture through `switchActiveDevice`.
    def switch_device_select(target)
      page.execute_script("document.querySelector(\"[data-huddle-target='#{target}']\").dispatchEvent(new Event('change', { bubbles: true }))")
    end

    # A device that vanished between listing and switching, such as an unplugged
    # USB headset, fails the switch without touching the call.
    def select_missing_device_option(target)
      page.execute_script(<<~JS, target)
        const select = document.querySelector(`[data-huddle-target='${arguments[0]}']`);
        const option = document.createElement('option');
        option.value = 'missing-device';
        option.text = 'Missing device';
        select.appendChild(option);
        select.value = 'missing-device';
        select.dispatchEvent(new Event('change', { bubbles: true }));
      JS
    end

    def microphone_meter_level
      page.evaluate_script("document.querySelector(\"[data-huddle-target='meter']\").getAttribute('aria-valuenow')").to_i
    end

    def microphone_meter_running
      page.evaluate_script(<<~JS)
        window.Stimulus
          .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle')
          ?.microphoneMeter?.running ?? false
      JS
    end

    def prejoin_meter_level
      page.evaluate_script("document.querySelector(\"[data-huddle-target='prejoinMeter']\").getAttribute('aria-valuenow')").to_i
    end

    def camera_preview_live?
      page.evaluate_script(<<~JS)
        (() => {
          const video = document.querySelector("[data-huddle-target='preview']");
          return Boolean(video && !video.closest("[data-huddle-target='previewWrap']").hidden &&
            video.readyState >= 2 && video.videoWidth > 0);
        })()
      JS
    end

    def connection_stat(target)
      page.evaluate_script("document.querySelector(\"[data-huddle-target='#{target}']\").textContent")
    end

    def connection_sampling?
      page.evaluate_script(<<~JS)
        window.Stimulus
          .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle')
          ?.connectionStatsTimer !== null
      JS
    end

    # A plain Error stands in for a download that failed and may succeed later.
    # A NotSupportedError stands in for a browser that simply cannot do this.
    def break_noise_suppression(error: nil)
      page.execute_script(<<~JS, error)
        const name = arguments[0];
        const addModule = AudioWorklet.prototype.addModule;
        AudioWorklet.prototype.addModule = function (url, ...rest) {
          if (String(url).includes('noise-suppressor-worklet')) {
            const failure = name
              ? new DOMException('Test noise suppressor refusal', name)
              : new Error('Test noise suppressor failure');
            return Promise.reject(failure);
          }
          return addModule.call(this, url, ...rest);
        };
      JS
    end

    def captured_credentials(index = 0)
      wait_for_condition("the browser did not capture huddle credentials") do
        page.evaluate_script("window.huddleTestCredentials.length") > index
      end
      page.evaluate_script("window.huddleTestCredentials[#{Integer(index)}]")
    end

    def huddle_credentials_count
      page.evaluate_script("window.huddleTestCredentials.length")
    end

    # The fake-media flags report microphone access as granted from the start,
    # so fresh-permission tests stub the query instead of depending on browser
    # state. Navigation clears the stub.
    def stub_microphone_permission(state)
      page.execute_script(<<~JS, state)
        const state = arguments[0];
        window.huddleTestPermissionsQuery ||= navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (description) => {
          if (description && description.name === 'microphone') return Promise.resolve({ state, onchange: null });
          return window.huddleTestPermissionsQuery(description);
        };
      JS
    end

    def restore_microphone_permission
      page.execute_script("navigator.permissions.query = window.huddleTestPermissionsQuery;")
    end

    def ignore_huddle_access_checks
      page.execute_script <<~'JS'
        const nativeAccessFetch = window.fetch.bind(window);
        window.fetch = (...args) => {
          const input = args[0];
          const options = args[1] || {};
          const url = typeof input === 'string' ? input : input.url;
          const method = (options.method || input.method || 'GET').toUpperCase();

          if (method === 'GET' && new URL(url, window.location.origin).pathname.match(/^\/rooms\/\d+\/huddle$/)) {
            return Promise.resolve(new Response('{}', {
              status: 200,
              headers: { 'Content-Type': 'application/json' }
            }));
          }

          return nativeAccessFetch(...args);
        };
      JS
    end

    def signal_socket_urls
      page.evaluate_script("window.huddleTestWebSocketUrls").select do |url|
        URI.parse(url).path.match?(%r{\A/rtc(?:/v1)?\z})
      end
    end

    def signal_token(url)
      URI.decode_www_form(URI.parse(url).query.to_s).to_h.fetch("access_token")
    end

    def wait_for_refreshed_token(original_token)
      refreshed_token = nil
      wait_for_condition("LiveKit did not give the SDK a refreshed token") do
        refreshed_token = page.evaluate_script(<<~JS)
          window.Stimulus
            .getControllerForElementAndIdentifier(document.getElementById('channel-huddle'), 'huddle')
            ?.room?.engine?.token
        JS
        refreshed_token.present? && refreshed_token != original_token
      end
      refreshed_token
    end

    def decode_token(token)
      JWT.decode(token, nil, false).first
    end

    def assert_tokens_unexpired(*tokens)
      tokens.each do |token|
        assert_operator decode_token(token).fetch("exp"), :>, Time.current.to_i,
          "gateway must reject an unexpired token because its authorization was revoked"
      end
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

    def assert_huddle_access_ended
      assert_selector "#channel-huddle[data-state='failed']", wait: 20
      assert_selector "[data-huddle-target='status']", text: "Huddle ended"
      assert_no_selector "#channel-huddle audio", visible: :all
      wait_for_condition("revoked participant's local media was not stopped") do
        page.evaluate_script("window.huddleTestLocalTracks.every(track => track.readyState === 'ended')")
      end
    end

    def assert_remaining_participant_connected
      assert_selector "#channel-huddle[data-state='connected']"
      assert_selector ".huddle__participant", count: 1
      wait_for_condition("the remaining participant lost their peer connection") do
        page.evaluate_script("window.huddleTestPeerConnections.some(connection => connection.connectionState === 'connected')")
      end
    end

    def assert_signal_token_rejected(signal_url, token)
      result = page.evaluate_async_script(<<~JS, signal_url, token)
        const template = arguments[0];
        const token = arguments[1];
        const done = arguments[arguments.length - 1];
        const url = new URL(template);
        url.searchParams.set('access_token', token);

        let finished = false;
        let opened = false;
        const finish = details => {
          if (finished) return;
          finished = true;
          clearTimeout(timeout);
          done({ opened, ...details });
        };
        const socket = new WebSocket(url);
        socket.addEventListener('open', () => {
          opened = true;
          socket.close();
        });
        socket.addEventListener('error', () => {});
        socket.addEventListener('close', event => finish({ code: event.code, timedOut: false }));
        const timeout = setTimeout(() => {
          socket.close();
          finish({ code: null, timedOut: true });
        }, 5_000);
      JS

      assert_not result.fetch("timedOut"), "gateway left an unauthorized signal attempt pending"
      assert_not result.fetch("opened"), "gateway accepted a signal socket with a revoked token"
    end

    def start_gateway
      gateway_log_path = Rails.root.join("tmp/livekit-gateway-system-test.log")
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

    def assert_media_received(kind)
      wait_for_condition("no #{kind} RTP media arrived from LiveKit") do
        page.evaluate_async_script(<<~JS, kind)
          const kind = arguments[0];
          const done = arguments[arguments.length - 1];
          Promise.all(window.huddleTestPeerConnections.map(pc => pc.getStats()))
            .then(reports => done(reports.some(report => Array.from(report.values()).some(stat =>
              stat.type === 'inbound-rtp' && stat.kind === kind && stat.bytesReceived > 0))))
            .catch(() => done(false));
        JS
      end
      assert_selected_local_candidate_is_relay if force_relay?
    end

    def assert_new_active_media_received(kind, after:)
      wait_for_condition("no #{kind} RTP media arrived on the reconnected peer connection") do
        page.evaluate_async_script(<<~JS, kind, after)
          const kind = arguments[0];
          const after = arguments[1];
          const done = arguments[arguments.length - 1];
          const activeConnections = window.huddleTestPeerConnections
            .slice(after)
            .filter(connection => ['connected', 'completed'].includes(connection.connectionState));
          Promise.all(activeConnections.map(connection => connection.getStats()))
            .then(reports => done(reports.some(report => Array.from(report.values()).some(stat =>
              stat.type === 'inbound-rtp' && stat.kind === kind && stat.bytesReceived > 0))))
            .catch(() => done(false));
        JS
      end
      assert_selected_local_candidate_is_relay(after:) if force_relay?
    end

    def assert_selected_local_candidate_is_relay(after: 0)
      candidate_types = []
      wait_for_condition("WebRTC did not select a relay candidate") do
        candidate_types = selected_local_candidate_types(after:)
        candidate_types.any? && candidate_types.all? { |type| type == "relay" }
      end
      assert_equal [ "relay" ], candidate_types.uniq
    end

    def selected_local_candidate_types(after:)
      page.evaluate_async_script(<<~JS, after)
        const after = arguments[0];
        const done = arguments[arguments.length - 1];
        const connections = window.huddleTestPeerConnections.slice(after);

        Promise.all(connections.map(connection => connection.getStats()))
          .then(reports => {
            const candidateTypes = reports.flatMap(report => {
              const pairs = [];
              report.forEach(stat => {
                if (stat.type === 'transport' && stat.selectedCandidatePairId) {
                  const pair = report.get(stat.selectedCandidatePairId);
                  if (pair) pairs.push(pair);
                }
              });
              if (pairs.length === 0) {
                report.forEach(stat => {
                  if (stat.type === 'candidate-pair' && stat.state === 'succeeded' && (stat.nominated || stat.selected)) {
                    pairs.push(stat);
                  }
                });
              }
              return pairs.map(pair => report.get(pair.localCandidateId)?.candidateType).filter(Boolean);
            });
            done(candidateTypes);
          })
          .catch(() => done([]));
      JS
    end

    def force_relay?
      ENV["LIVEKIT_SYSTEM_TEST_FORCE_RELAY"] == "1"
    end

    def inbound_rtp_bytes(kind)
      page.evaluate_async_script(<<~JS, kind)
        const kind = arguments[0];
        const done = arguments[arguments.length - 1];
        Promise.all(window.huddleTestPeerConnections.map(connection => connection.getStats()))
          .then(reports => done(reports.reduce((total, report) => total + Array.from(report.values())
            .filter(stat => stat.type === 'inbound-rtp' && stat.kind === kind)
            .reduce((bytes, stat) => bytes + stat.bytesReceived, 0), 0)))
          .catch(() => done(-1));
      JS
    end

    def assert_inbound_media_stopped(kind)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      previous_bytes = inbound_rtp_bytes(kind)
      assert_operator previous_bytes, :>=, 0, "could not read inbound #{kind} RTP statistics"
      stable_samples = 0

      loop do
        sleep 0.25
        current_bytes = inbound_rtp_bytes(kind)
        assert_operator current_bytes, :>=, 0, "could not read inbound #{kind} RTP statistics"
        stable_samples = current_bytes == previous_bytes ? stable_samples + 1 : 0
        return assert true if stable_samples >= 4

        flunk "#{kind} RTP bytes kept increasing after server revocation" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        previous_bytes = current_bytes
      end
    end

    def with_rescuable_server_exceptions
      env_config = Rails.application.env_config
      original = env_config["action_dispatch.show_exceptions"]
      env_config["action_dispatch.show_exceptions"] = :rescuable
      yield
    ensure
      env_config["action_dispatch.show_exceptions"] = original
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
