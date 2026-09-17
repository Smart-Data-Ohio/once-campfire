require "test_helper"

class Rooms::Stage::RolesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"

    @room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    @listener = @room.memberships.find_by!(user: users(:jason))
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
  end

  test "a host promotes a listener, clearing their hand and revoking their grants" do
    @listener.raise_hand!
    grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @listener)
    host_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    sign_in :david

    # The revoked grant refreshes the header stack on the room stream and a
    # sidebar stack on every member's stream. Then the role change delivers a
    # per-viewer roster to every member, plus the personalized panel and the
    # rejoin event to the affected member.
    assert_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count }, 1 do
      assert_difference -> { capture_turbo_stream_broadcasts([ users(:jason), :rooms ]).count }, 4 do
        assert_difference -> { capture_turbo_stream_broadcasts([ users(:david), :rooms ]).count }, 2 do
          patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }
        end
      end
    end

    assert_redirected_to room_url(@room)
    assert_equal "speaker", @listener.reload.stage_role
    assert_not_predicate @listener, :hand_raised?
    assert grant.reload.revoked?
    assert HuddleCleanup.exists?(operation: :remove_participant, huddle_grant_id: grant.id)
    assert_not host_grant.reload.revoked?

    roster_target = ActionView::RecordIdentifier.dom_id(@room, :stage_roster)
    listener_roster = capture_turbo_stream_broadcasts([ users(:kevin), :rooms ])
      .find { |stream| stream["target"] == roster_target }
    assert_no_match "Invite to speak", listener_roster.to_html
    assert_no_match "Make host", listener_roster.to_html

    host_roster = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
      .find { |stream| stream["target"] == roster_target }
    assert_match "Invite to speak", host_roster.to_html
  end

  test "the affected member's panel replacement carries no rejoin trigger" do
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    streams = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
    assert_equal 3, streams.count

    panel = streams.find { |stream| stream["target"] == ActionView::RecordIdentifier.dom_id(@room, :stage_panel) }
    assert_equal "replace", panel["action"]
    assert_no_match "stage-rejoin", panel.to_html
    assert_match "You are speaking", panel.to_html

    event = streams.find { |stream| stream["action"] == "append" }
    assert_equal "huddle_role_events", event["target"]
  end

  test "every role change appends a rejoin event to the member's persistent target" do
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    streams = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
    event = streams.find { |stream| stream["action"] == "append" }
    assert_equal "huddle_role_events", event["target"]
    assert_match "data-huddle-rejoin-room-id=\"#{@room.id}\"", event.to_html
    assert_match "data-huddle-rejoin-stage-role=\"speaker\"", event.to_html
  end

  test "a demotion appends a rejoin event to the member's persistent target" do
    @listener.change_stage_role!("speaker")
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "listener" }

    streams = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
    event = streams.find { |stream| stream["action"] == "append" }
    assert_equal "huddle_role_events", event["target"]
    assert_match "data-huddle-rejoin-room-id=\"#{@room.id}\"", event.to_html
    assert_match "data-huddle-rejoin-stage-role=\"listener\"", event.to_html
  end

  test "a turbo-stream role change replaces the roster without navigating" do
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match ActionView::RecordIdentifier.dom_id(@room, :stage_roster), response.body
  end

  test "a host demotes a speaker back to the audience" do
    @listener.change_stage_role!("speaker")
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "listener" }

    assert_redirected_to room_url(@room)
    assert_equal "listener", @listener.reload.stage_role
  end

  test "a host demoting themselves is allowed unless they are the last host" do
    host = @room.memberships.find_by!(user: users(:david))
    sign_in :david

    patch room_stage_role_url(@room, host), params: { stage_role: "speaker" }

    assert_response :unprocessable_entity
    assert_equal "Stage role can't demote the last host", response.body
    assert_equal "host", host.reload.stage_role

    @listener.change_stage_role!("host")
    patch room_stage_role_url(@room, host), params: { stage_role: "speaker" }

    assert_redirected_to room_url(@room)
    assert_equal "speaker", host.reload.stage_role
  end

  test "a failed last-host demotion revokes nothing" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @room.memberships.find_by!(user: users(:david)))
    sign_in :david

    patch room_stage_role_url(@room, @room.memberships.find_by!(user: users(:david))), params: { stage_role: "listener" }

    assert_response :unprocessable_entity
    assert_not grant.reload.revoked?
  end

  test "a listener cannot change anyone's role" do
    sign_in :kevin

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    assert_response :forbidden
    assert_equal "listener", @listener.reload.stage_role
  end

  test "a speaker cannot change anyone's role" do
    @room.memberships.find_by!(user: users(:kevin)).change_stage_role!("speaker")
    sign_in :kevin

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    assert_response :forbidden
    assert_equal "listener", @listener.reload.stage_role
  end

  test "an administrator member manages roles without being a host" do
    users(:kevin).update!(role: :administrator)
    sign_in :kevin

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    assert_redirected_to room_url(@room)
    assert_equal "speaker", @listener.reload.stage_role
  end

  test "an administrator who is not a member gets not found" do
    users(:jz).update!(role: :administrator)
    sign_in :jz

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    assert_response :not_found
    assert_equal "listener", @listener.reload.stage_role
  end

  test "non-members get not found" do
    sign_in :jz

    patch room_stage_role_url(@room, @listener), params: { stage_role: "speaker" }

    assert_response :not_found
    assert_equal "listener", @listener.reload.stage_role
  end

  test "changing a non-member's role is not found" do
    sign_in :david

    patch room_stage_role_url(@room, 0), params: { stage_role: "speaker" }

    assert_response :not_found
  end

  test "an unknown role is unprocessable" do
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "heckler" }

    assert_response :unprocessable_entity
    assert_equal "Unknown stage role", response.body
    assert_equal "listener", @listener.reload.stage_role
  end

  test "a missing role is unprocessable" do
    sign_in :david

    patch room_stage_role_url(@room, @listener)

    assert_response :unprocessable_entity
    assert_equal "listener", @listener.reload.stage_role
  end

  test "roles do not exist outside stage rooms" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    sign_in :david

    patch room_stage_role_url(voice, voice.memberships.find_by!(user: users(:jason))), params: { stage_role: "speaker" }

    assert_response :not_found
  end
end
