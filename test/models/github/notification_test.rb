require "test_helper"

class Github::NotificationTest < ActiveSupport::TestCase
  setup do
    @subscription = Github::RepositorySubscription.create!(
      room: rooms(:designers), owner: "rails", repo: "rails", created_by: users(:david))
  end

  test "claim! wins once per subscription and dedupe key" do
    notification = Github::Notification.claim!(subscription: @subscription, dedupe_key: "opened:rails/rails#12")

    assert notification.persisted?
    assert_nil Github::Notification.claim!(subscription: @subscription, dedupe_key: "opened:rails/rails#12")
  end

  test "claim! is scoped to the subscription" do
    other = Github::RepositorySubscription.create!(
      room: rooms(:watercooler), owner: "rails", repo: "rails", created_by: users(:david))

    assert Github::Notification.claim!(subscription: @subscription, dedupe_key: "opened:rails/rails#12")
    assert Github::Notification.claim!(subscription: other, dedupe_key: "opened:rails/rails#12")
  end

  test "claim! survives a duplicate insert race" do
    Github::Notification.create!(subscription: @subscription, dedupe_key: "opened:rails/rails#12")

    Github::Notification.stubs(:create!).raises(ActiveRecord::RecordNotUnique)
    assert_nil Github::Notification.claim!(subscription: @subscription, dedupe_key: "opened:rails/rails#12")
  end
end
