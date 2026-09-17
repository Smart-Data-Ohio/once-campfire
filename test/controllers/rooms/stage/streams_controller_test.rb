require "test_helper"

class Rooms::Stage::StreamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"

    @room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    @host = @room.memberships.find_by!(user: users(:david))
    @listener = @room.memberships.find_by!(user: users(:jason))
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "a host goes live, broadcasting the badge, dot, and panels" do
    HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"), membership: @host)
    sign_in :david

    assert_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count }, 1 do
      assert_difference -> { capture_turbo_stream_broadcasts([ users(:david), :rooms ]).count }, 2 do
        assert_difference -> { capture_turbo_stream_broadcasts([ users(:jason), :rooms ]).count }, 2 do
          assert_difference -> { Stream.live.count }, 1 do
            post room_stage_stream_url(@room), params: { quality: "1080p30" }
          end
        end
      end
    end

    assert_redirected_to room_url(@room)

    stream = @room.live_stream
    assert_equal "1080p30", stream.quality
    assert_equal users(:david), stream.user
    assert_equal @host, stream.membership
  end

  test "a speaker goes live" do
    @listener.change_stage_role!("speaker")
    HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @listener)
    sign_in :jason

    post room_stage_stream_url(@room), params: { quality: "720p15" }

    assert_redirected_to room_url(@room)
    assert_equal users(:jason), @room.live_stream.user
  end

  test "a turbo-stream start swaps the actor's own panel without navigating" do
    HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"), membership: @host)
    sign_in :david

    post room_stage_stream_url(@room), params: { quality: "1080p15" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match ActionView::RecordIdentifier.dom_id(@room, :stage_panel), response.body
    assert_match "Live: David", response.body
    assert_match "Stop stream", response.body
  end

  test "a listener cannot go live" do
    sign_in :kevin

    assert_no_difference -> { Stream.live.count } do
      post room_stage_stream_url(@room), params: { quality: "1080p15" }
    end

    assert_response :forbidden
    assert_equal "Only hosts and speakers can go live", response.body
  end

  test "an administrator listener cannot go live" do
    users(:jason).update!(role: :administrator)
    sign_in :jason

    post room_stage_stream_url(@room), params: { quality: "1080p15" }

    assert_response :forbidden
    assert_nil @room.live_stream
  end

  test "a host without a huddle grant cannot go live" do
    sign_in :david

    assert_no_difference -> { Stream.live.count } do
      post room_stage_stream_url(@room), params: { quality: "1080p15" }
    end

    assert_response :forbidden
    assert_equal "Join the stage before going live", response.body
  end

  test "a host whose grant was revoked cannot go live" do
    grant = HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"), membership: @host)
    grant.revoke!
    sign_in :david

    assert_no_difference -> { Stream.live.count } do
      post room_stage_stream_url(@room), params: { quality: "1080p15" }
    end

    assert_response :forbidden
    assert_equal "Join the stage before going live", response.body
  end

  test "an unknown quality is unprocessable" do
    HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"), membership: @host)
    sign_in :david

    assert_no_difference -> { Stream.live.count } do
      post room_stage_stream_url(@room), params: { quality: "4k60" }
    end

    assert_response :unprocessable_entity
    assert_equal "Unknown stream quality", response.body
  end

  test "a missing quality is unprocessable" do
    HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"), membership: @host)
    sign_in :david

    post room_stage_stream_url(@room)

    assert_response :unprocessable_entity
    assert_nil @room.live_stream
  end

  test "starting while another stream is live returns conflict naming the presenter" do
    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    @listener.change_stage_role!("speaker")
    HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @listener)
    sign_in :jason

    assert_no_difference -> { Stream.live.count } do
      post room_stage_stream_url(@room), params: { quality: "720p15" }
    end

    assert_response :conflict
    assert_equal "David is already live", response.body
  end

  test "the presenter stops the stream" do
    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    sign_in :david

    assert_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count }, 1 do
      assert_difference -> { capture_turbo_stream_broadcasts([ users(:jason), :rooms ]).count }, 2 do
        delete room_stage_stream_url(@room)
      end
    end

    assert_redirected_to room_url(@room)
    assert_nil @room.live_stream
  end

  test "a speaker presenter stops their own stream" do
    @listener.change_stage_role!("speaker")
    Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")
    sign_in :jason

    delete room_stage_stream_url(@room)

    assert_redirected_to room_url(@room)
    assert_nil @room.live_stream
  end

  test "a host stops another member's stream" do
    @listener.change_stage_role!("speaker")
    Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")
    sign_in :david

    delete room_stage_stream_url(@room)

    assert_redirected_to room_url(@room)
    assert_nil @room.live_stream
  end

  test "a host stop appends a stream-stopped event for the presenter" do
    @listener.change_stage_role!("speaker")
    Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")
    sign_in :david

    delete room_stage_stream_url(@room)

    event = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
      .find { |broadcast| broadcast["action"] == "append" }
    assert_equal "huddle_role_events", event["target"]
    assert_match "data-huddle-stream-room-id=\"#{@room.id}\"", event.to_html
    assert_match "data-huddle-stream-kind=\"stream-stopped\"", event.to_html
  end

  test "a presenter stop appends no stream-stopped event" do
    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    sign_in :david

    delete room_stage_stream_url(@room)

    appends = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
      .select { |broadcast| broadcast["action"] == "append" }
    assert_empty appends
  end

  test "an administrator member stops the stream without being a host" do
    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    users(:kevin).update!(role: :administrator)
    sign_in :kevin

    delete room_stage_stream_url(@room)

    assert_redirected_to room_url(@room)
    assert_nil @room.live_stream
  end

  test "a listener cannot stop the stream" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    sign_in :kevin

    delete room_stage_stream_url(@room)

    assert_response :forbidden
    assert_predicate stream.reload, :live?
  end

  test "a speaker who is not the presenter cannot stop the stream" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    @room.memberships.find_by!(user: users(:kevin)).change_stage_role!("speaker")
    sign_in :kevin

    delete room_stage_stream_url(@room)

    assert_response :forbidden
    assert_predicate stream.reload, :live?
  end

  test "stopping with nothing live succeeds for hosts and stays silent" do
    sign_in :david

    assert_no_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count } do
      delete room_stage_stream_url(@room)
    end

    assert_redirected_to room_url(@room)
  end

  test "stopping with nothing live is forbidden for listeners" do
    sign_in :kevin

    delete room_stage_stream_url(@room)

    assert_response :forbidden
  end

  test "a turbo-stream stop swaps the actor's own panel without navigating" do
    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    sign_in :david

    delete room_stage_stream_url(@room), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "Go live", response.body
    assert_no_match "Live: David", response.body
  end

  test "non-members get not found" do
    sign_in :jz

    post room_stage_stream_url(@room), params: { quality: "1080p15" }
    assert_response :not_found

    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    delete room_stage_stream_url(@room)
    assert_response :not_found
    assert_predicate Stream.live.first, :live?
  end

  test "an administrator who is not a member gets not found" do
    users(:jz).update!(role: :administrator)
    sign_in :jz

    post room_stage_stream_url(@room), params: { quality: "1080p15" }

    assert_response :not_found
    assert_nil @room.live_stream
  end

  test "streams do not exist outside stage rooms" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    sign_in :david

    post room_stage_stream_url(voice), params: { quality: "1080p15" }
    assert_response :not_found

    delete room_stage_stream_url(voice)
    assert_response :not_found
  end

  test "demoting the presenter to listener ends the stream in the same transaction" do
    @listener.change_stage_role!("speaker")
    stream = Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")
    sign_in :david

    patch room_stage_role_url(@room, @listener), params: { stage_role: "listener" }

    assert_redirected_to room_url(@room)
    assert_equal "listener", @listener.reload.stage_role
    assert_not_predicate stream.reload, :live?
    assert_nil @room.live_stream
  end

  test "removing the presenter through the members edit ends the stream" do
    @listener.change_stage_role!("speaker")
    stream = Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")
    HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @listener)
    sign_in :david

    patch rooms_stage_url(@room), params: { room: { name: "Town Hall" }, user_ids: [ users(:david).id, users(:kevin).id ] }

    assert_redirected_to room_url(@room)
    assert_not_predicate stream.reload, :live?
  end

  test "promoting a speaker keeps no live stream dangling" do
    @listener.change_stage_role!("speaker")
    stream = Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")
    grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @listener)
    sign_in :david

    # Any role change revokes the member's grants, and the last revoked grant
    # ends the stream: rejoining drops the share, so nothing stays live.
    patch room_stage_role_url(@room, @listener), params: { stage_role: "host" }

    assert_redirected_to room_url(@room)
    assert grant.reload.revoked?
    assert_not_predicate stream.reload, :live?
  end
end
