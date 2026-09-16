require "test_helper"

class Huddle::PushInvitationJobTest < ActiveSupport::TestCase
  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    @item = ActivityItem.find_by!(user: users(:jason), source: grant)
    @room = rooms(:david_and_jason)
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "pushes the invitation to the recipient only" do
    Rails.configuration.x.web_push_pool.expects(:queue).once.with do |payload, subscriptions|
      assert_equal "David started a huddle", payload[:title]
      assert_equal Rails.application.routes.url_helpers.room_path(@room), payload[:path]
      assert_equal [ users(:jason).id ], subscriptions.order(:id).pluck(:user_id)
      true
    end

    Huddle::PushInvitationJob.perform_now(@item.id)
  end

  test "an opted-out recipient gets no push subscriptions" do
    memberships(:jason_david_and_jason).update!(involvement: "nothing")

    Rails.configuration.x.web_push_pool.expects(:queue).once.with do |payload, subscriptions|
      assert_equal "David started a huddle", payload[:title]
      assert_empty subscriptions
      true
    end

    Huddle::PushInvitationJob.perform_now(@item.id)
  end

  test "a connected recipient gets no push" do
    memberships(:jason_david_and_jason).connected

    Rails.configuration.x.web_push_pool.expects(:queue).once.with do |payload, subscriptions|
      assert_empty subscriptions
      true
    end

    Huddle::PushInvitationJob.perform_now(@item.id)
  end

  test "missing invitations are ignored" do
    Rails.configuration.x.web_push_pool.expects(:queue).never

    @item.destroy!
    Huddle::PushInvitationJob.perform_now(@item.id)
  end
end
