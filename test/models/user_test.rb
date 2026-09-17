require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "user does not prevent very long passwords" do
    users(:david).update(password: "secret" * 50)
    assert users(:david).valid?
  end

  test "creating users grants membership to the open rooms" do
    assert_difference -> { Membership.count }, +Rooms::Open.count do
      create_new_user
    end
  end

  test "deactivating a user deletes push subscriptions, searches, memberships for non-direct rooms, and changes their email address" do
    assert_difference -> { Membership.count }, -users(:david).memberships.without_direct_rooms.count do
    assert_difference -> { Push::Subscription.count }, -users(:david).push_subscriptions.count do
    assert_difference -> { Search.count }, -users(:david).searches.count do
      SecureRandom.stubs(:uuid).returns("2e7de450-cf04-4fa8-9b02-ff5ab2d733e7")
      users(:david).deactivate
      assert_equal "david-deactivated-2e7de450-cf04-4fa8-9b02-ff5ab2d733e7@37signals.com", users(:david).reload.email_address
    end
    end
    end
  end

  test "deactivating a user deletes their sessions" do
    assert_changes -> { users(:david).sessions.count }, from: 1, to: 0 do
      users(:david).deactivate
    end
  end

  test "deactivating enqueues calendar cleanup syncs that remove the user's entries" do
    user = users(:david)
    EventCalendarEntry.create!(event: events(:launch_party), user:, google_event_id: "stale" * 8)

    assert_enqueued_with(job: Calendar::SyncEntryJob, args: [ events(:launch_party).id, user.id ]) do
      user.deactivate
    end

    perform_enqueued_jobs only: Calendar::SyncEntryJob

    assert_not EventCalendarEntry.exists?(user:)
  end

  test "deactivating disconnects the user's Google account" do
    account = GoogleAccount.create!(user: users(:david), email: "david@gmail.test",
      refresh_token: "refresh-token", access_token: "access-token", access_token_expires_at: 1.hour.from_now)

    users(:david).deactivate

    assert_equal "Account deactivated", account.reload.disconnected_reason
    assert_not_predicate account, :usable?
  end

  test "github logins are unique among present values" do
    users(:david).update!(github_login: "david-gh")
    users(:jason).github_login = "David-GH"

    assert_not users(:jason).valid?
    assert_equal [ "is already linked to another user" ], users(:jason).errors[:github_login]

    users(:jason).github_login = nil
    assert users(:jason).valid?
  end

  test "skipping the open room grant leaves memberships unmanaged" do
    assert_no_difference -> { Membership.count } do
      User.create_bot!(name: "Managed Bot", skip_open_room_grant: true)
    end
  end

  private
    def create_new_user
      User.create!(name: "User", email_address: "user@example.com", password: "secret123456")
    end
end
