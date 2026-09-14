require "application_system_test_case"

class HuddlesTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ], options: { name: :huddle_chrome } do |options|
    options.add_argument "--use-fake-device-for-media-stream"
    options.add_argument "--use-fake-ui-for-media-stream"
    options.add_argument "--autoplay-policy=no-user-gesture-required"
  end

  setup do
    skip "Run with LIVEKIT_SYSTEM_TESTS=1 and a local LiveKit server" unless ENV["LIVEKIT_SYSTEM_TESTS"] == "1"
    assert Huddle.configured?, "Source the local LiveKit environment before running huddle tests"
    Huddle::RoomService.new.delete_room(room_name: Huddle.room_name(rooms(:designers).id))
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    if ENV["LIVEKIT_SYSTEM_TESTS"] == "1"
      [ :default, "Kevin" ].each do |name|
        using_session(name) do
          if page.has_css?("#channel-huddle:not([hidden])", wait: 0)
            find("[data-action='huddle#leave']").click
            assert_no_selector "#channel-huddle:not([hidden])"
          end
        end
      end
      ActionController::Base.allow_forgery_protection = @forgery_protection
      Huddle::RoomService.new.delete_room(room_name: Huddle.room_name(rooms(:designers).id))
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

  test "denied microphone leaves no ghost participant and can be retried" do
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    prepare_browser
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
    page.execute_script <<~JS
      window.huddleTestGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('Test permission denial', 'NotAllowedError'));
    JS
    click_button "Join huddle"
    assert_selector "#channel-huddle[data-state='failed']"
    assert_selector "[data-huddle-target='notice']", text: /Microphone access was denied/
    using_session("Kevin") { assert_selector ".huddle__participant", count: 1 }

    page.execute_script "navigator.mediaDevices.getUserMedia = window.huddleTestGetUserMedia"
    click_button "Try again"
    assert_selector "#channel-huddle[data-state='connected']"
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"
  end

  test "server removal disconnects only the targeted participant and stops their media" do
    open_huddle_as "jz@37signals.com"
    using_session("Kevin") { open_huddle_as "kevin@37signals.com" }
    assert_selector ".huddle__participant", count: 2
    assert_media_received "audio"

    # Exercise the real server API without relying on the client's access poll
    # or a Campfire navigation to end the connection.
    session = users(:jz).sessions.order(:created_at).last
    Huddle::RevokeParticipantJob.perform_now(Huddle.room_name(rooms(:designers).id), Huddle.identity(session.id))

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

  private
    def open_huddle_as(email)
      prepare_browser
      sign_in email
      join_room rooms(:designers)
      click_button "Join huddle"
      assert_selector "#channel-huddle[data-state='connected']", wait: 20
      assert_button "Mute", exact: true
    end

    def prepare_browser
      page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        window.huddleTestPeerConnections = [];
        window.huddleTestLocalTracks = [];
        const NativePeerConnection = window.RTCPeerConnection;
        window.RTCPeerConnection = class extends NativePeerConnection {
          constructor(...args) {
            super(...args);
            window.huddleTestPeerConnections.push(this);
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
      JS
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
