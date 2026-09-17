require "test_helper"

class Huddle::InvitationResolverTest < ActiveSupport::TestCase
  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    @item = ActivityItem.find_by!(user: users(:jason), source: grant)
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "an unanswered invitation becomes a missed call and stays unread" do
    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_equal "huddle_missed", @item.reload.event_type
    assert_predicate @item, :unread?
  end

  test "a recipient who was issued a grant since the start has their invitation handled" do
    # Created directly to simulate an issuance concurrent with resolution;
    # issue! itself would have handled the open invitation as a join.
    travel 10.seconds do
      HuddleGrant.create!(
        identity: "campfire-participant-#{SecureRandom.hex(32)}",
        room_name: Huddle.room_name(rooms(:david_and_jason).id),
        session: Session.create!(user: users(:jason), user_agent: "join", ip_address: "127.0.0.3"),
        user: users(:jason),
        membership: memberships(:jason_david_and_jason),
        room: rooms(:david_and_jason),
        last_issued_at: Time.current
      )
    end

    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_predicate @item.reload, :handled?
  end

  test "a recipient seen in the call has their invitation handled" do
    grant = HuddleGrant.create!(
      identity: "campfire-participant-#{SecureRandom.hex(32)}",
      room_name: Huddle.room_name(rooms(:david_and_jason).id),
      session: Session.create!(user: users(:jason), user_agent: "join", ip_address: "127.0.0.3"),
      user: users(:jason),
      membership: memberships(:jason_david_and_jason),
      room: rooms(:david_and_jason),
      last_issued_at: 1.hour.ago,
      last_seen_at: Time.current
    )
    assert grant.in_call?

    travel 46.seconds do
      # The gateway keeps touching liveness while the call continues.
      grant.update_columns(last_seen_at: Time.current)
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_predicate @item.reload, :handled?
  end

  test "the starter leaving before the wait elapses is a missed call" do
    @item.source.revoke!

    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_equal "huddle_missed", @item.reload.event_type
    assert_predicate @item, :unread?
  end

  test "an invitation within the wait is left alone" do
    travel 44.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_equal "huddle_started", @item.reload.event_type
    assert_predicate @item, :unread?
  end

  test "an already-handled invitation is left alone" do
    @item.mark_handled!

    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_equal "huddle_started", @item.reload.event_type
    assert_predicate @item, :handled?
  end

  test "resolving twice keeps a single missed item" do
    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
      Huddle::InvitationResolver.resolve_overdue!
    end

    assert_equal "huddle_missed", @item.reload.event_type
    assert_equal 1, ActivityItem.where(user: users(:jason)).count
  end

  test "resolution can be scoped to one user" do
    # Created directly: issuing through issue! would handle the recipient's
    # own open invitation for the room as a join.
    other_grant = HuddleGrant.create!(
      identity: "campfire-participant-#{SecureRandom.hex(32)}",
      room_name: Huddle.room_name(rooms(:david_and_jason).id),
      session: Session.create!(user: users(:jason), user_agent: "second", ip_address: "127.0.0.4"),
      user: users(:jason),
      membership: memberships(:jason_david_and_jason),
      room: rooms(:david_and_jason)
    )
    other_item = ActivityItems::Recorder.record!(recipient: users(:david), source: other_grant, event_type: "huddle_started")

    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!(user: users(:jason))
    end

    assert_equal "huddle_missed", @item.reload.event_type
    assert_equal "huddle_started", other_item.reload.event_type
  end
end
