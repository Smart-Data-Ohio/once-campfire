require "test_helper"

class ActivityItemTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @original_api_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_SECRET"] = "test-api-secret"
    @user = users(:david)
    @source = messages(:first)
    @item = ActivityItem.create!(user: @user, source: @source, event_type: "mention")
  end

  teardown do
    ENV["LIVEKIT_API_SECRET"] = @original_api_secret
  end

  test "state transitions preserve the distinction between unread, read, and handled" do
    assert_predicate @item, :unread?
    assert_equal "unread", @item.state

    @item.mark_read!
    assert_predicate @item, :read?
    assert_equal "read", @item.state

    @item.mark_handled!
    assert_predicate @item, :handled?
    assert @item.read_at.present?
    assert_not @item.read?
    assert_equal "handled", @item.state

    @item.mark_unhandled!
    assert_predicate @item, :read?
    assert_equal "read", @item.state

    @item.mark_unread!
    assert_predicate @item, :unread?
    assert_equal "unread", @item.state
  end

  test "state changes notify the recipient's activity stream" do
    stream = ActivityChannel.stream_name_for(@user.id)

    assert_broadcasts stream, 1 do
      @item.mark_read!
    end

    assert_broadcasts stream, 1 do
      @item.mark_handled!
    end

    assert_broadcasts stream, 1 do
      @item.mark_unhandled!
    end

    assert_broadcasts stream, 1 do
      @item.mark_unread!
    end
  end

  test "marking a handled item unread clears both state timestamps" do
    @item.mark_handled!
    @item.mark_unread!

    assert_predicate @item.reload, :unread?
    assert_nil @item.read_at
    assert_nil @item.handled_at
  end

  test "accessible items follow current membership and active human access" do
    assert_includes ActivityItem.accessible_to(@user), @item

    memberships(:david_designers).delete
    assert_not ActivityItem.accessible_to(@user).exists?(@item.id)
  end

  test "inactive users and bots cannot access activity items" do
    assert_empty ActivityItem.accessible_to(users(:bender))

    @user.update!(status: :deactivated)
    assert_empty ActivityItem.accessible_to(@user)
  end

  test "huddle invitations are accessible until the recipient loses room access" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    item = ActivityItem.find_by!(user: users(:jason), source: grant)

    assert_includes ActivityItem.accessible_to(users(:jason)), item
    assert_not_includes ActivityItem.accessible_to(users(:david)), item

    memberships(:jason_david_and_jason).delete
    assert_not ActivityItem.accessible_to(users(:jason)).exists?(item.id)
  end

  test "a huddle invitation broadcast carries the banner payload" do
    grant = nil
    assert_broadcasts ActivityChannel.stream_name_for(users(:jason).id), 1 do
      grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    end

    item = ActivityItem.find_by!(user: users(:jason), source: grant)
    assert_broadcast_on(ActivityChannel.stream_name_for(users(:jason).id), {
      activityItemId: item.id,
      huddleInvitation: {
        activityItemId: item.id,
        eventType: "huddle_started",
        state: "unread",
        roomId: rooms(:david_and_jason).id,
        roomName: "David",
        roomPath: Rails.application.routes.url_helpers.room_path(rooms(:david_and_jason)),
        callerName: "David",
        readPath: Rails.application.routes.url_helpers.read_activity_item_path(item, state: "read"),
        handledPath: Rails.application.routes.url_helpers.handled_activity_item_path(item, state: "handled")
      }
    })
  end

  test "converting an invitation to missed notifies the recipient's activity stream" do
    grant = HuddleGrant.issue!(session: sessions(:david_safari), membership: memberships(:david_david_and_jason))
    item = ActivityItem.find_by!(user: users(:jason), source: grant)
    stream = ActivityChannel.stream_name_for(users(:jason).id)

    assert_broadcasts stream, 1 do
      item.update!(event_type: "huddle_missed")
    end
  end
end
