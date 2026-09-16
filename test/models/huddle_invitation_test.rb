require "test_helper"

class HuddleInvitationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    @room = rooms(:david_and_jason)
    @starter_membership = memberships(:david_david_and_jason)
    @starter_session = sessions(:david_safari)
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "issuing a grant in a one-to-one DM invites only the other participant" do
    assert_enqueued_with(job: Huddle::MissedHuddleJob) do
      assert_enqueued_with(job: Huddle::PushInvitationJob) do
        HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      end
    end

    item = ActivityItem.find_by!(user: users(:jason), event_type: "huddle_started")
    assert_equal HuddleGrant.polymorphic_name, item.source_type
    assert_equal @room.id, item.source.room_id
    assert_equal users(:david).id, item.source.user_id
    assert_predicate item, :unread?
    assert_not ActivityItem.exists?(user: users(:david), event_type: "huddle_started")
  end

  test "the missed follow-up waits 45 seconds" do
    freeze_time do
      assert_enqueued_with(job: Huddle::MissedHuddleJob, at: 45.seconds.from_now) do
        HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      end
    end
  end

  test "channel huddles create no invitation" do
    assert_no_difference -> { ActivityItem.count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: @starter_session, membership: memberships(:david_watercooler))
      end
    end
  end

  test "no invitation when the other participant already holds an active grant" do
    HuddleGrant.issue!(session: second_session_for(users(:jason)), membership: memberships(:jason_david_and_jason))
    assert_equal 1, ActivityItem.where(user: users(:david), event_type: "huddle_started").count

    assert_no_difference -> { ActivityItem.where(user: users(:jason)).count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      end
    end
  end

  test "a second grant for the same starter does not ring again inside two minutes" do
    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    assert_equal 1, ActivityItem.where(user: users(:jason), event_type: "huddle_started").count

    assert_no_difference -> { ActivityItem.where(user: users(:jason), event_type: "huddle_started").count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: second_session_for(users(:david)), membership: @starter_membership)
      end
    end
  end

  test "a handled invitation does not suppress the next ring" do
    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    ActivityItem.find_by!(user: users(:jason)).mark_handled!

    assert_difference -> { ActivityItem.where(user: users(:jason), event_type: "huddle_started").count }, 1 do
      HuddleGrant.issue!(session: second_session_for(users(:david)), membership: @starter_membership)
    end
  end

  test "an invitation older than two minutes does not suppress the next ring" do
    travel_to 3.minutes.ago do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    end
    assert_equal 1, ActivityItem.where(user: users(:jason), event_type: "huddle_started").count

    assert_difference -> { ActivityItem.where(user: users(:jason), event_type: "huddle_started").count }, 1 do
      HuddleGrant.issue!(session: second_session_for(users(:david)), membership: @starter_membership)
    end
  end

  test "direct rooms without exactly two human users get no invitation" do
    assert_no_difference -> { ActivityItem.count } do
      HuddleGrant.issue!(session: second_session_for(users(:kevin)), membership: memberships(:kevin_bender_and_kevin))
    end

    group_room = Rooms::Direct.create_for({ creator: users(:david) }, users: [ users(:david), users(:jason), users(:kevin) ])
    assert_no_difference -> { ActivityItem.count } do
      HuddleGrant.issue!(session: @starter_session, membership: group_room.memberships.find_by(user: users(:david)))
    end
  end

  private
    def second_session_for(user)
      Session.create!(user: user, user_agent: "second device", ip_address: "127.0.0.2")
    end
end
