require "test_helper"

class HuddleGrantTest < ActiveSupport::TestCase
  setup do
    @environment_names = Huddle::REQUIRED_ENVIRONMENT
    @original_livekit_environment = ENV.values_at(*@environment_names)
    ENV["LIVEKIT_URL"] = "wss://huddle.example.test"
    ENV["LIVEKIT_INTERNAL_URL"] = "ws://livekit.example.test:7880"
    ENV["LIVEKIT_API_KEY"] = "test-api-key"
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    ENV["LIVEKIT_GATEWAY_SECRET"] = "test-gateway-secret"
  end

  teardown do
    @environment_names.zip(@original_livekit_environment).each do |name, value|
      ENV[name] = value
    end
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

  test "issuing an open channel grant refreshes every sidebar and the header" do
    room = rooms(:hq)

    assert_presence_broadcast(room) do
      HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_hq))
    end
  end

  test "issuing a closed channel grant refreshes every sidebar and the header" do
    room = rooms(:watercooler)

    assert_presence_broadcast(room) do
      HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))
    end
  end

  test "issuing a direct grant refreshes both sidebars and the header" do
    room = rooms(:david_and_jason)

    assert_presence_broadcast(room) do
      HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    end
  end

  test "revoking a channel grant refreshes every sidebar and the header" do
    room = rooms(:watercooler)
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    assert_presence_broadcast(room) do
      grant.revoke!
    end
  end

  test "revoking a direct grant refreshes both sidebars and the header" do
    room = rooms(:david_and_jason)
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))

    assert_presence_broadcast(room) do
      grant.revoke!
    end
  end

  test "first sighting in a channel refreshes presence, later sightings stay silent" do
    room = rooms(:watercooler)
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    assert_presence_broadcast(room) do
      grant.record_seen!
    end

    assert_no_changes -> { capture_turbo_stream_broadcasts([ room, :messages ]).count } do
      travel 11.seconds do
        grant.record_seen!
      end
    end
  end

  test "no presence broadcasts without huddle configuration" do
    ENV.delete("LIVEKIT_GATEWAY_SECRET")
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

  test "a stage grant records the membership role it was issued for" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    host_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))
    listener_grant = HuddleGrant.issue!(
      session: users(:jason).sessions.create!(user_agent: "Test"),
      membership: room.memberships.find_by!(user: users(:jason)))

    assert_equal "host", host_grant.stage_role
    assert_equal "listener", listener_grant.stage_role
    assert_predicate host_grant, :authorized?
    assert_predicate listener_grant, :authorized?
  end

  test "non-stage grants record no role" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_watercooler))

    assert_nil grant.stage_role
    assert_predicate grant, :authorized?
  end

  test "a stage role change revokes the member's active grants with cleanup" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    membership = room.memberships.find_by!(user: users(:jason))
    membership.change_stage_role!("speaker")
    grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: membership)
    other_grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))

    membership.change_stage_role!("listener")

    assert grant.reload.revoked?
    assert HuddleCleanup.exists?(operation: :remove_participant, huddle_grant_id: grant.id)
    assert_not other_grant.reload.revoked?
  end

  test "authorize_or_revoke! revokes a grant whose issued role no longer matches" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    membership = room.memberships.find_by!(user: users(:jason))
    membership.change_stage_role!("speaker")
    grant = HuddleGrant.issue!(session: users(:jason).sessions.create!(user_agent: "Test"), membership: membership)

    assert grant.authorize_or_revoke!

    # As if the role-change revocation was missed: the per-second gateway
    # check still catches the mismatch through authorization.
    membership.update_columns(stage_role: "listener")

    assert_not grant.authorize_or_revoke!
    assert grant.reload.revoked?
    assert HuddleCleanup.exists?(operation: :remove_participant, huddle_grant_id: grant.id)
  end

  test "rejoining after a role change issues a new grant for the new role" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    membership = room.memberships.find_by!(user: users(:jason))
    session = users(:jason).sessions.create!(user_agent: "Test")
    old_grant = HuddleGrant.issue!(session: session, membership: membership)

    membership.change_stage_role!("speaker")
    new_grant = HuddleGrant.issue!(session: session, membership: membership.reload)

    assert old_grant.reload.revoked?
    assert_not_equal old_grant.id, new_grant.id
    assert_not_equal old_grant.identity, new_grant.identity
    assert_equal "speaker", new_grant.stage_role
    assert_predicate new_grant, :authorized?
  end

  test "issuing a stage grant refreshes the presence stacks" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    membership = room.memberships.find_by!(user: users(:david))

    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
      assert_turbo_stream_broadcasts [ users(:jason), :rooms ], count: 1 do
        assert_turbo_stream_broadcasts [ room, :messages ], count: 1 do
          HuddleGrant.issue!(session: sessions(:david_safari), membership: membership)
        end
      end
    end
  end

  test "revoking a stage grant refreshes the presence stacks" do
    room = Rooms::Stage.create_for({ name: "Town Hall", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: room.memberships.find_by!(user: users(:david)))

    assert_difference -> { capture_turbo_stream_broadcasts([ users(:david), :rooms ]).count } do
      assert_difference -> { capture_turbo_stream_broadcasts([ users(:jason), :rooms ]).count } do
        assert_difference -> { capture_turbo_stream_broadcasts([ room, :messages ]).count } do
          grant.revoke!
        end
      end
    end
  end

  private
    # The block sends each member's sidebar stack and the room header stack
    # exactly one replace broadcast apiece.
    def assert_presence_broadcast(room)
      streams = room.users.map { |user| [ user, :rooms ] } + [ [ room, :messages ] ]
      before = streams.map { |stream| capture_turbo_stream_broadcasts(stream).count }

      yield

      streams.zip(before) do |stream, count|
        broadcasts = capture_turbo_stream_broadcasts(stream)
        assert_equal count + 1, broadcasts.count, "expected one presence broadcast on #{stream.inspect}"
        assert_equal "replace", broadcasts.last["action"]
      end

      room.users.each do |user|
        assert_equal dom_id(room, :sidebar_voice_participants),
          capture_turbo_stream_broadcasts([ user, :rooms ]).last["target"]
      end
      assert_equal dom_id(room, :header_voice_participants),
        capture_turbo_stream_broadcasts([ room, :messages ]).last["target"]
    end
end
