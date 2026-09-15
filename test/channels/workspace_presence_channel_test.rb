require "test_helper"

class WorkspacePresenceChannelTest < ActionCable::Channel::TestCase
  setup do
    @user = users(:david)
    @session = sessions(:david_safari)
    stub_connection(current_user: @user, current_session: @session)
  end

  test "subscribing establishes a server-owned presence lease" do
    assert_difference -> { WorkspacePresenceLease.count }, +1 do
      subscribe
    end

    assert subscription.confirmed?
    lease = WorkspacePresenceLease.last
    assert_equal @user, lease.user
    assert_equal @session, lease.session
    assert_match(/\A[0-9a-f-]{36}\z/, lease.connection_id)
  end

  test "unsubscribing deletes only this connection lease" do
    other_lease = WorkspacePresenceLease.establish(user: @user, session: @session)
    subscribe
    channel_lease = WorkspacePresenceLease.where.not(id: other_lease.id).sole

    unsubscribe

    assert_not WorkspacePresenceLease.exists?(channel_lease.id)
    assert WorkspacePresenceLease.exists?(other_lease.id)
  end

  test "heartbeat extends the lease" do
    subscribe
    lease = WorkspacePresenceLease.last
    initial_expiry = lease.expires_at

    travel 25.seconds do
      perform :heartbeat
    end

    assert_operator lease.reload.expires_at, :>, initial_expiry
  end

  test "heartbeat rejects and deletes presence after session revocation" do
    subscribe
    lease = WorkspacePresenceLease.last
    Session.delete(@session.id)

    perform :heartbeat

    assert subscription.rejected?
    assert_not WorkspacePresenceLease.exists?(lease.id)
  end

  test "heartbeat replaces a valid lease that was pruned" do
    subscribe
    original_lease = WorkspacePresenceLease.last
    original_lease.delete

    assert_difference -> { WorkspacePresenceLease.count }, +1 do
      perform :heartbeat
    end

    assert_not_equal original_lease.id, WorkspacePresenceLease.last.id
    assert_not subscription.rejected?
  end

  test "rejects a subscription without a verified session" do
    stub_connection(current_user: @user, current_session: nil)

    assert_no_difference -> { WorkspacePresenceLease.count } do
      subscribe
    end

    assert subscription.rejected?
  end
end
