require "test_helper"

class StreamTest < ActiveSupport::TestCase
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

  test "quality must be a known preset" do
    Stream::QUALITIES.each do |quality|
      stream = Stream.new(room: @room, membership: @host, user: users(:david), quality: quality)
      assert_predicate stream, :valid?, "expected #{quality} to be valid"
    end

    stream = Stream.new(room: @room, membership: @host, user: users(:david), quality: "4k60")
    assert_not_predicate stream, :valid?
    assert_equal [ "is not included in the list" ], stream.errors[:quality]
  end

  test "started_at defaults to now" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    assert_in_delta Time.current, stream.started_at, 5.seconds
  end

  test "live scope only returns unended streams" do
    live = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    other_room = Rooms::Stage.create_for({ name: "Side Stage", creator: users(:david) }, users: [ users(:david) ])
    ended = Stream.create!(room: other_room, membership: other_room.memberships.find_by!(user: users(:david)),
      user: users(:david), quality: "720p15")
    ended.end!

    assert_equal [ live ], Stream.live.to_a
  end

  test "one live stream per room" do
    Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Stream.create!(room: @room, membership: @host, user: users(:david), quality: "720p15")
    end
  end

  test "an ended stream frees the room for another" do
    first = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    first.end!

    second = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "720p15")

    assert_predicate second, :live?
    assert_equal second, @room.live_stream
  end

  test "end! is idempotent" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    stream.end!
    ended_at = stream.ended_at

    stream.end!

    assert_equal ended_at, stream.reload.ended_at
  end

  test "starting broadcasts the badge, dot, and per-viewer panel" do
    assert_turbo_stream_broadcasts [ @room, :messages ], count: 1 do
      assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 2 do
        assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 2 do
          Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
        end
      end
    end

    badge = capture_turbo_stream_broadcasts([ @room, :messages ]).first
    assert_equal ActionView::RecordIdentifier.dom_id(@room, :stage_live_badge), badge["target"]
    assert_match "Live: David", badge.to_html

    dot = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
      .find { |stream| stream["target"] == ActionView::RecordIdentifier.dom_id(@room, :sidebar_stage_live) }
    assert_match "stage-live-dot__pip", dot.to_html

    panel = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
      .find { |stream| stream["target"] == ActionView::RecordIdentifier.dom_id(@room, :stage_panel) }
    assert_match "Live: David", panel.to_html
    assert_no_match "Stop stream", panel.to_html

    host_panel = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
      .find { |stream| stream["target"] == ActionView::RecordIdentifier.dom_id(@room, :stage_panel) }
    assert_match "Stop stream", host_panel.to_html
  end

  test "ending broadcasts the cleared badge, dot, and panel" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    assert_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count }, 1 do
      assert_difference -> { capture_turbo_stream_broadcasts([ users(:jason), :rooms ]).count }, 2 do
        stream.end!
      end
    end

    badge = capture_turbo_stream_broadcasts([ @room, :messages ]).last
    assert_no_match "Live: David", badge.to_html

    panel = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
      .select { |stream| stream["target"] == ActionView::RecordIdentifier.dom_id(@room, :stage_panel) }.last
    assert_no_match "Live: David", panel.to_html
  end

  test "ending twice broadcasts once" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    assert_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count }, 1 do
      stream.end!
      stream.end!
    end
  end

  test "a host stop appends a stream-stopped event to the presenter's persistent target" do
    @listener.change_stage_role!("speaker")
    stream = Stream.create!(room: @room, membership: @listener, user: users(:jason), quality: "1080p15")

    stream.end!(ended_by: users(:david))

    event = capture_turbo_stream_broadcasts([ users(:jason), :rooms ])
      .find { |broadcast| broadcast["action"] == "append" }
    assert_equal "huddle_role_events", event["target"]
    assert_match "data-huddle-stream-room-id=\"#{@room.id}\"", event.to_html
    assert_match "data-huddle-stream-kind=\"stream-stopped\"", event.to_html
  end

  test "a presenter stop appends no stream-stopped event" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    assert_difference -> { capture_turbo_stream_broadcasts([ users(:david), :rooms ]).count }, 2 do
      stream.end!(ended_by: users(:david))
    end

    appends = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
      .select { |broadcast| broadcast["action"] == "append" }
    assert_empty appends
  end

  test "an automatic end appends no stream-stopped event" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    stream.end!

    appends = capture_turbo_stream_broadcasts([ users(:david), :rooms ])
      .select { |broadcast| broadcast["action"] == "append" }
    assert_empty appends
  end

  test "revoking the presenter's last grant for the room ends the stream" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @host)
    other_grant = HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Test"), membership: @host)

    grant.revoke!
    assert_predicate stream.reload, :live?

    other_grant.revoke!
    assert_not_predicate stream.reload, :live?
  end

  test "revoking another member's grant leaves the stream live" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: @listener)

    grant.revoke!

    assert_predicate stream.reload, :live?
  end

  test "a grant revoked through authorization ends the stream" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: @host)

    # The gateway's per-second check finds a grant whose role no longer
    # matches the membership and revokes through authorization.
    grant.update_columns(stage_role: "listener")

    assert_not grant.authorize_or_revoke!
    assert_not_predicate stream.reload, :live?
  end

  test "removing the presenter's membership ends the stream" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    HuddleGrant.issue!(session: sessions(:david_safari), membership: @host)

    # A second host keeps the room manageable; the removal itself is what ends
    # the stream, through the membership's grant revocation.
    @listener.change_stage_role!("host")
    @host.destroy!

    assert_not_predicate stream.reload, :live?
  end

  test "removing the presenter's membership without grants ends the stream and broadcasts the end" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    assert_not HuddleGrant.active.where(membership_id: @host.id).exists?

    @listener.change_stage_role!("host")

    assert_difference -> { capture_turbo_stream_broadcasts([ @room, :messages ]).count }, 1 do
      @host.destroy!
    end

    assert_not_predicate stream.reload, :live?

    badge = capture_turbo_stream_broadcasts([ @room, :messages ]).last
    assert_no_match "Live: David", badge.to_html
  end

  test "deactivating the presenter ends the stream" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    HuddleGrant.issue!(session: sessions(:david_safari), membership: @host)

    users(:david).deactivate

    assert_not_predicate stream.reload, :live?
  end

  test "deactivating the presenter ends the stream even without grants" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")
    assert_not HuddleGrant.active.where(membership_id: @host.id).exists?

    users(:david).deactivate

    assert_not_predicate stream.reload, :live?
  end

  test "destroying the room destroys its streams" do
    stream = Stream.create!(room: @room, membership: @host, user: users(:david), quality: "1080p15")

    @room.destroy!

    assert_not Stream.exists?(stream.id)
  end

  test "revoking a grant outside a stage room runs no stream queries" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    queries = capture_sql { grant.revoke! }

    assert_no_match(/FROM "streams"/, queries.join("\n"))
  end

  private
    def capture_sql
      queries = []
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveRecord::Base.connection_pool.clear_query_cache
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
