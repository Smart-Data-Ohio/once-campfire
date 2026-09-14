require "test_helper"

class WorkspacePresenceLeaseTest < ActiveSupport::TestCase
  setup do
    @user = users(:david)
    @session = sessions(:david_safari)
  end

  test "an unexpired lease backed by an existing session makes its user online" do
    lease = WorkspacePresenceLease.establish(user: @user, session: @session)

    assert_includes WorkspacePresenceLease.online_user_ids([ @user.id ]), @user.id
    assert lease.connection_id.present?
  end

  test "a stale lease does not make its user online" do
    WorkspacePresenceLease.establish(user: @user, session: @session)

    travel WorkspacePresenceLease::TTL + 1.second

    assert_not_includes WorkspacePresenceLease.online_user_ids([ @user.id ]), @user.id
  end

  test "deleting one lease leaves a user online while another connection is live" do
    first_lease = WorkspacePresenceLease.establish(user: @user, session: @session)
    WorkspacePresenceLease.establish(user: @user, session: @session)

    first_lease.delete

    assert_includes WorkspacePresenceLease.online_user_ids([ @user.id ]), @user.id
  end

  test "a lease without its session does not make its user online" do
    lease = WorkspacePresenceLease.establish(user: @user, session: @session)

    Session.delete(@session.id)

    assert_not_includes WorkspacePresenceLease.online_user_ids([ @user.id ]), @user.id
    assert_not WorkspacePresenceLease.exists?(lease.id), "the database must remove leases even when callbacks are skipped"
  end

  test "refresh deletes the lease when its session has been revoked" do
    lease = WorkspacePresenceLease.establish(user: @user, session: @session)
    Session.delete(@session.id)

    assert_not lease.refresh
    assert_not WorkspacePresenceLease.exists?(lease.id)
  end

  test "cannot establish or refresh presence for an inactive user" do
    lease = WorkspacePresenceLease.establish(user: @user, session: @session)
    User.where(id: @user.id).update_all(status: User.statuses.fetch("deactivated"))

    assert_not_includes WorkspacePresenceLease.online_user_ids([ @user.id ]), @user.id
    assert_not lease.refresh
    assert_not WorkspacePresenceLease.exists?(lease.id)
    assert_nil WorkspacePresenceLease.establish(user: @user, session: @session)
  end

  test "cannot establish a lease for another user's session" do
    assert_nil WorkspacePresenceLease.establish(user: users(:jason), session: @session)
  end

  test "online lookup rejects a lease whose session belongs to another user" do
    lease = WorkspacePresenceLease.establish(user: @user, session: @session)
    lease.update_column(:user_id, users(:jason).id)

    assert_not_includes WorkspacePresenceLease.online_user_ids([ users(:jason).id ]), users(:jason).id
  end

  test "prune removes expired leases in bounded batches" do
    2.times { WorkspacePresenceLease.establish(user: @user, session: @session) }
    WorkspacePresenceLease.update_all(expires_at: 1.minute.ago)

    assert_difference -> { WorkspacePresenceLease.count }, -1 do
      WorkspacePresenceLease.prune(limit: 1)
    end
    assert_equal 1, WorkspacePresenceLease.count
  end
end
