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
    assert_enqueued_with(job: Huddle::PushInvitationJob) do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    end

    item = ActivityItem.find_by!(user: users(:jason), event_type: "huddle_started")
    assert_equal HuddleGrant.polymorphic_name, item.source_type
    assert_equal @room.id, item.source.room_id
    assert_equal users(:david).id, item.source.user_id
    assert_predicate item, :unread?
    assert_not ActivityItem.exists?(user: users(:david), event_type: "huddle_started")
  end

  test "issuing a grant never schedules a delayed job" do
    # Production runs the :resque adapter without resque-scheduler, whose
    # enqueue_at raises NotImplementedError. Invitations must only enqueue
    # immediate jobs; overdue resolution runs in the reconciler loop instead.
    ActiveJob::Base.queue_adapter.stubs(:enqueue_at).raises(NotImplementedError)

    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)

    assert ActivityItem.exists?(user: users(:jason), event_type: "huddle_started")
  end

  test "a recipient with notifications off or invisible gets no invitation" do
    memberships(:jason_david_and_jason).update!(involvement: "nothing")

    assert_no_difference -> { ActivityItem.where(user: users(:jason)).count } do
      assert_no_enqueued_jobs only: Huddle::PushInvitationJob do
        HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      end
    end

    memberships(:jason_david_and_jason).update!(involvement: "invisible")

    assert_no_difference -> { ActivityItem.where(user: users(:jason)).count } do
      HuddleGrant.issue!(session: second_session_for(users(:david)), membership: @starter_membership)
    end
  end

  test "a recipient with huddle items switched off still gets the banner but no item" do
    users(:jason).update!(inbox_preferences: { "huddle_invitations" => false })

    assert_no_difference -> { ActivityItem.where(user: users(:jason)).count } do
      assert_no_enqueued_jobs only: Huddle::PushInvitationJob do
        assert_broadcasts ActivityChannel.stream_name_for(users(:jason).id), 1 do
          HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
        end
      end
    end

    assert_broadcast_on(ActivityChannel.stream_name_for(users(:jason).id), {
      activityItemId: nil,
      huddleInvitation: {
        activityItemId: nil,
        eventType: "huddle_started",
        state: "unread",
        roomId: @room.id,
        roomName: "David",
        roomPath: Rails.application.routes.url_helpers.room_path(@room),
        callerName: "David",
        readPath: nil,
        handledPath: nil
      }
    })

    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end
    assert_not ActivityItem.exists?(user: users(:jason))
  end

  test "channel huddles create no invitation" do
    assert_no_difference -> { ActivityItem.count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: @starter_session, membership: memberships(:david_watercooler))
      end
    end
  end

  test "voice channel huddles create no invitation" do
    room = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])

    assert_no_difference -> { ActivityItem.count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: @starter_session, membership: room.memberships.find_by!(user: users(:david)))
      end
    end
  end

  test "no invitation while the other participant is in the call" do
    recipient_grant = HuddleGrant.issue!(session: second_session_for(users(:jason)), membership: memberships(:jason_david_and_jason))
    recipient_grant.update_columns(last_seen_at: Time.current)

    assert_no_difference -> { ActivityItem.where(user: users(:jason)).count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      end
    end
  end

  test "an invitation fires when the other participant's grant went quiet" do
    recipient_grant = HuddleGrant.issue!(session: second_session_for(users(:jason)), membership: memberships(:jason_david_and_jason))
    recipient_grant.update_columns(last_seen_at: 21.seconds.ago)

    assert_difference -> { ActivityItem.where(user: users(:jason), event_type: "huddle_started").count }, 1 do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    end
  end

  test "reusing the same grant rings again once the dedup window has passed" do
    grant = HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    first_item = ActivityItem.find_by!(user: users(:jason), source: grant)

    travel 3.minutes do
      assert_broadcasts ActivityChannel.stream_name_for(users(:jason).id), 1 do
        assert_enqueued_with(job: Huddle::PushInvitationJob) do
          assert_equal grant, HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
        end
      end
    end

    assert_equal 1, ActivityItem.where(user: users(:jason)).count
    first_item.reload
    assert_equal "huddle_started", first_item.event_type
    assert_predicate first_item, :unread?
    assert_operator first_item.created_at, :>, 1.minute.ago
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

  test "no ring inside the two-minute window after a missed invitation" do
    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    ActivityItem.find_by!(user: users(:jason)).update!(event_type: "huddle_missed")

    assert_no_difference -> { ActivityItem.where(user: users(:jason)).count } do
      assert_no_enqueued_jobs do
        HuddleGrant.issue!(session: second_session_for(users(:david)), membership: @starter_membership)
      end
    end
  end

  test "a handled invitation still suppresses the next ring inside two minutes" do
    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    item = ActivityItem.find_by!(user: users(:jason)).mark_handled!

    assert_no_enqueued_jobs only: Huddle::PushInvitationJob do
      HuddleGrant.issue!(session: second_session_for(users(:david)), membership: @starter_membership)
    end

    assert_predicate item.reload, :handled?
    assert_equal 1, ActivityItem.where(user: users(:jason)).count
  end

  test "an invitation older than two minutes re-rings through the same row" do
    item = nil
    travel_to 3.minutes.ago do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      item = ActivityItem.find_by!(user: users(:jason), event_type: "huddle_started")
    end

    assert_enqueued_with(job: Huddle::PushInvitationJob, args: [ item.id ]) do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    end

    assert_equal 1, ActivityItem.where(user: users(:jason)).count
    assert_operator item.reload.created_at, :>, 1.minute.ago
  end

  test "a handled invitation older than two minutes re-rings through the same row" do
    item = nil
    travel_to 3.minutes.ago do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      item = ActivityItem.find_by!(user: users(:jason)).mark_handled!
    end

    assert_enqueued_with(job: Huddle::PushInvitationJob, args: [ item.id ]) do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    end

    assert_equal 1, ActivityItem.where(user: users(:jason)).count
    item.reload
    assert_equal "huddle_started", item.event_type
    assert_predicate item, :unread?
    assert_operator item.created_at, :>, 1.minute.ago
  end

  test "a missed invitation older than two minutes re-rings through the same row" do
    item = nil
    travel_to 3.minutes.ago do
      HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
      item = ActivityItem.find_by!(user: users(:jason))
      item.update!(event_type: "huddle_missed")
    end

    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)

    item.reload
    assert_equal "huddle_started", item.event_type
    assert_predicate item, :unread?
    assert_equal 1, ActivityItem.where(user: users(:jason)).count
  end

  test "obtaining a grant clears the recipient's open invitations for the room" do
    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    item = ActivityItem.find_by!(user: users(:jason), event_type: "huddle_started")

    HuddleGrant.issue!(session: second_session_for(users(:jason)), membership: memberships(:jason_david_and_jason))

    assert_predicate item.reload, :handled?
  end

  test "joining late clears the missed item" do
    HuddleGrant.issue!(session: @starter_session, membership: @starter_membership)
    item = ActivityItem.find_by!(user: users(:jason))

    travel 46.seconds do
      Huddle::InvitationResolver.resolve_overdue!
    end
    assert_equal "huddle_missed", item.reload.event_type

    HuddleGrant.issue!(session: second_session_for(users(:jason)), membership: memberships(:jason_david_and_jason))

    assert_predicate item.reload, :handled?
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
