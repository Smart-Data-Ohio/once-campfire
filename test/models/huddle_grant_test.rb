require "test_helper"

class HuddleGrantTest < ActiveSupport::TestCase
  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "an active session and membership reuse one random grant" do
    membership = memberships(:david_watercooler)
    session = sessions(:david_safari)

    first = HuddleGrant.issue!(session: session, membership: membership)
    second = HuddleGrant.issue!(session: session, membership: membership)

    assert_equal first, second
    assert_match(/\Acampfire-participant-[0-9a-f]{64}\z/, first.identity)
    assert first.authorized?
  end

  test "revoking and restoring room membership never resurrects the old grant" do
    membership = memberships(:david_watercooler)
    session = sessions(:david_safari)
    old_grant = HuddleGrant.issue!(session: session, membership: membership)

    membership.destroy!
    replacement_membership = Membership.create!(user: membership.user, room: membership.room)
    new_grant = HuddleGrant.issue!(session: session, membership: replacement_membership)

    assert old_grant.reload.revoked?
    assert_not_equal old_grant.id, new_grant.id
    assert_not_equal old_grant.identity, new_grant.identity
  end

  test "issuance rejects a stale or cross-user membership" do
    assert_raises(HuddleGrant::Ineligible) do
      HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:kevin_designers))
    end

    stale_membership = memberships(:david_watercooler)
    stale_membership.delete
    assert_raises(HuddleGrant::Ineligible) do
      HuddleGrant.issue!(session: sessions(:david_safari), membership: stale_membership)
    end
  end

  test "issuance stops after three uniqueness conflicts" do
    HuddleGrant.expects(:create!).times(3).raises(ActiveRecord::RecordNotUnique)

    assert_raises(ActiveRecord::RecordNotUnique) do
      HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))
    end
  end

  test "issuance stamps last_issued_at on create and on reuse" do
    membership = memberships(:david_watercooler)
    session = sessions(:david_safari)

    grant = nil
    travel_to 1.hour.ago do
      grant = HuddleGrant.issue!(session:, membership:)
      assert_equal Time.current, grant.last_issued_at
    end

    travel_to 30.minutes.ago do
      assert_equal grant, HuddleGrant.issue!(session:, membership:)
      assert_equal Time.current, grant.reload.last_issued_at
    end
  end

  test "in_call reflects gateway liveness within twenty seconds" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    assert_not_predicate grant, :in_call?

    grant.update_columns(last_seen_at: 19.seconds.ago)
    assert_predicate grant.reload, :in_call?
    assert_includes HuddleGrant.in_call, grant

    grant.update_columns(last_seen_at: 21.seconds.ago)
    assert_not_predicate grant.reload, :in_call?
    assert_not_includes HuddleGrant.in_call, grant
  end

  test "record_seen! persists liveness at most once per ten seconds" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    freeze_time do
      grant.record_seen!
      assert_equal Time.current, grant.reload.last_seen_at
    end

    travel 9.seconds do
      assert_no_changes -> { grant.reload.last_seen_at } do
        grant.record_seen!
      end
    end

    travel 11.seconds do
      assert_changes -> { grant.reload.last_seen_at } do
        grant.record_seen!
      end
    end
  end

  test "participants_for lists distinct in-call users by name" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    david_membership = room.memberships.find_by!(user: users(:david))
    jason_membership = room.memberships.find_by!(user: users(:jason))
    kevin_membership = room.memberships.find_by!(user: users(:kevin))

    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: david_membership)
    david_grant.update_columns(last_seen_at: Time.current)
    # A second session for the same user still counts as one participant.
    other_david_grant = HuddleGrant.issue!(session: users(:david).sessions.create!(user_agent: "Other"), membership: david_membership)
    other_david_grant.update_columns(last_seen_at: Time.current)

    jason_grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: jason_membership)
    jason_grant.update_columns(last_seen_at: Time.current)

    # Issued but never seen: not in the call.
    HuddleGrant.issue!(session: users(:kevin).sessions.create!(user_agent: "Test"), membership: kevin_membership)

    assert_equal [ users(:david), users(:jason) ], HuddleGrant.participants_for(room)
  end

  test "participants_for drops revoked and quiet grants" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    david_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    david_grant.update_columns(last_seen_at: Time.current)
    jason_grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: room.memberships.find_by!(user: users(:jason)))
    jason_grant.update_columns(last_seen_at: Time.current)

    assert_equal [ users(:david), users(:jason) ], HuddleGrant.participants_for(room)

    david_grant.revoke!
    assert_equal [ users(:jason) ], HuddleGrant.participants_for(room)

    jason_grant.update_columns(last_seen_at: 21.seconds.ago)
    assert_empty HuddleGrant.participants_for(room)
  end

  test "issuing a voice grant refreshes the presence stacks" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    membership = room.memberships.find_by!(user: users(:david))

    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
      assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
        assert_turbo_stream_broadcasts [ room, :messages ], count: 1 do
          HuddleGrant.issue!(session: sessions(:david_safari), membership: membership)
        end
      end
    end
  end

  test "revoking a voice grant refreshes the presence stacks" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))

    assert_difference -> { capture_turbo_stream_broadcasts([ users(:david), :rooms ]).count } do
      assert_difference -> { capture_turbo_stream_broadcasts([ users(:jason), :rooms ]).count } do
        assert_difference -> { capture_turbo_stream_broadcasts([ room, :messages ]).count } do
          grant.revoke!
        end
      end
    end
  end

  test "first sighting in the call refreshes voice presence, later sightings stay silent" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.first!)

    assert_difference -> { capture_turbo_stream_broadcasts([ room, :messages ]).count } do
      grant.record_seen!
    end

    assert_no_changes -> { capture_turbo_stream_broadcasts([ room, :messages ]).count } do
      travel 11.seconds do
        grant.record_seen!
      end
    end
  end

  test "channel grants never refresh voice presence" do
    membership = memberships(:david_watercooler)

    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 0 do
      assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 0 do
        assert_turbo_stream_broadcasts [ rooms(:watercooler), :messages ], count: 0 do
          grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: membership)
          grant.record_seen!
          grant.revoke!
        end
      end
    end
  end

  test "revoking a destroyed room's grants stays silent" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])
    HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.first!)

    assert_no_changes -> { capture_turbo_stream_broadcasts([ room, :messages ]).count } do
      room.destroy!
    end
  end
end
