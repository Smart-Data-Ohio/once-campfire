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
end
