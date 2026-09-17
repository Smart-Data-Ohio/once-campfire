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
end
