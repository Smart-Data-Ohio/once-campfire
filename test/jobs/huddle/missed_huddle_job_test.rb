require "test_helper"

class Huddle::MissedHuddleJobTest < ActiveSupport::TestCase
  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    @item = ActivityItem.find_by!(user: users(:jason), source: grant)
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "an unanswered invitation becomes a missed call and stays unread" do
    Huddle::MissedHuddleJob.perform_now(@item.id)

    assert_equal "huddle_missed", @item.reload.event_type
    assert_predicate @item, :unread?
  end

  test "a recipient who joined has their invitation handled automatically" do
    HuddleGrant.issue!(
      session: Session.create!(user: users(:jason), user_agent: "join", ip_address: "127.0.0.3"),
      membership: memberships(:jason_david_and_jason)
    )

    Huddle::MissedHuddleJob.perform_now(@item.id)

    assert_predicate @item.reload, :handled?
  end

  test "the starter leaving before the wait elapses is a missed call" do
    @item.source.revoke!

    Huddle::MissedHuddleJob.perform_now(@item.id)

    assert_equal "huddle_missed", @item.reload.event_type
    assert_predicate @item, :unread?
  end

  test "an already-handled invitation is left alone" do
    @item.mark_handled!

    Huddle::MissedHuddleJob.perform_now(@item.id)

    assert_equal "huddle_started", @item.reload.event_type
    assert_predicate @item, :handled?
  end

  test "missing invitations are ignored" do
    @item.destroy!

    assert_nil Huddle::MissedHuddleJob.perform_now(@item.id)
  end
end
