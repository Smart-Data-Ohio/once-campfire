require "test_helper"

class TypingNotificationsChannelTest < ActionCable::Channel::TestCase
  tests TypingNotificationsChannel

  setup do
    @room = rooms(:designers)
    @user = users(:kevin)
    @thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Thread typing")
    stub_connection(current_user: @user)
  end

  test "root typing remains on the parent room stream" do
    subscribe room_id: @room.id

    assert subscription.confirmed?
    assert_has_stream TypingNotificationsChannel.broadcasting_for(@room)
    assert_broadcast_on TypingNotificationsChannel.broadcasting_for(@room), action: :start, user: @user.slice(:id, :name) do
      perform :start
    end
  end

  test "thread typing uses a separate stream and never broadcasts into the channel" do
    subscribe room_id: @room.id, thread_id: @thread.id

    assert subscription.confirmed?
    assert_has_stream TypingNotificationsChannel.broadcasting_for(@thread)
    refute_includes subscription.streams, TypingNotificationsChannel.broadcasting_for(@room)
    assert_no_broadcasts TypingNotificationsChannel.broadcasting_for(@room) do
      assert_broadcast_on TypingNotificationsChannel.broadcasting_for(@thread), action: :start, user: @user.slice(:id, :name) do
        perform :start
      end
    end
  end

  test "a thread cannot be subscribed through another room" do
    subscribe room_id: rooms(:watercooler).id, thread_id: @thread.id

    assert subscription.rejected?
  end

  test "revoked membership stops typing and prevents reconnection" do
    subscribe room_id: @room.id, thread_id: @thread.id
    assert subscription.confirmed?
    @room.memberships.revoke_from(@user)

    assert_no_broadcasts TypingNotificationsChannel.broadcasting_for(@thread) do
      perform :start
    end

    subscribe room_id: @room.id, thread_id: @thread.id
    assert subscription.rejected?
  end
end
