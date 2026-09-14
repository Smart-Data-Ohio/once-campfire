require "test_helper"

class HuddleRevocationTest < ActiveSupport::TestCase
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
    @environment_names.zip(@original_livekit_environment).each { |name, value| ENV[name] = value }
  end

  test "membership revocation persists cleanup for only that grant" do
    membership = memberships(:david_watercooler)
    target = issue_grant(sessions(:david_safari), membership)
    other_membership = Membership.find_by!(room: membership.room, user: users(:jason))
    other = issue_grant(users(:jason).sessions.create!(user_agent: "Other"), other_membership)

    membership.destroy!

    assert target.reload.revoked?
    assert_not other.reload.revoked?
    assert_equal [ target.id ], participant_cleanups.pluck(:huddle_grant_id)
  end

  test "session removal revokes its grants in every room and leaves another session active" do
    target_session = sessions(:david_safari)
    target_grants = users(:david).memberships.limit(2).map { |membership| issue_grant(target_session, membership) }
    other_session = users(:david).sessions.create!(user_agent: "Other device")
    other_grant = issue_grant(other_session, memberships(:david_watercooler))

    target_session.destroy!

    assert target_grants.all? { |grant| grant.reload.revoked? }
    assert_not other_grant.reload.revoked?
    assert_equal target_grants.map(&:id).sort, participant_cleanups.pluck(:huddle_grant_id).sort
  end

  test "banning a user revokes grants even though sessions are bulk deleted first" do
    user = users(:kevin)
    membership = user.memberships.first!
    grants = 2.times.map { issue_grant(user.sessions.create!(user_agent: "Test"), membership) }

    user.ban

    assert grants.all? { |grant| grant.reload.revoked? }
    assert_equal grants.map(&:id).sort, participant_cleanups.pluck(:huddle_grant_id).sort
  end

  test "deactivating a user revokes grants after memberships and sessions are bulk deleted" do
    user = users(:david)
    session = sessions(:david_safari)
    grants = user.memberships.limit(2).map { |membership| issue_grant(session, membership) }

    user.deactivate

    assert grants.all? { |grant| grant.reload.revoked? }
    assert_equal grants.map(&:id).sort, participant_cleanups.pluck(:huddle_grant_id).sort
  end

  test "destroying a room revokes grants and persists one room deletion" do
    room = rooms(:watercooler)
    grant = issue_grant(sessions(:david_safari), memberships(:david_watercooler))

    room.destroy!

    assert grant.reload.revoked?
    assert_empty participant_cleanups
    deletion = HuddleCleanup.find_by!(operation: :delete_room)
    assert_equal grant.room_name, deletion.room_name
  end

  test "revocation remains durable while LiveKit is unavailable" do
    grant = issue_grant(sessions(:david_safari), memberships(:david_watercooler))
    ENV.delete("LIVEKIT_INTERNAL_URL")

    memberships(:david_watercooler).destroy!

    assert grant.reload.revoked?
    cleanup = HuddleCleanup.find_by!(operation: :remove_participant, huddle_grant_id: grant.id)
    assert_nil cleanup.completed_at
    assert_nil cleanup.enqueued_at
  end

  private
    def issue_grant(session, membership)
      HuddleGrant.issue!(session: session, membership: membership)
    end

    def participant_cleanups
      HuddleCleanup.where(operation: :remove_participant)
    end
end
