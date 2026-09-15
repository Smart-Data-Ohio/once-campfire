require "test_helper"

class ActivityItems::RecorderTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @author = users(:jz)
    @recipient = users(:david)
  end

  test "records a mention for an opted-in active human and excludes the author" do
    message = @room.messages.create!(
      creator: @author,
      body: "Hey #{mention_attachment_for(:david)}",
      client_message_id: "activity-mention"
    )

    item = ActivityItem.find_by!(user: @recipient, source: message)
    assert_equal "mention", item.event_type
    assert_not ActivityItem.exists?(user: @author, source: message)
    assert_not ActivityItem.exists?(user: users(:bender), source: message)
  end

  test "a reply follows the reply author's current preference" do
    source = @room.messages.create!(creator: @recipient, body: "Original", client_message_id: "activity-reply-source")
    reply = @room.messages.create!(
      creator: @author,
      body: "Reply",
      reply_to_message: source,
      client_message_id: "activity-reply"
    )

    assert_equal "reply", ActivityItem.find_by!(user: @recipient, source: reply).event_type

    memberships(:david_designers).update!(involvement: "nothing")
    suppressed_source = @room.messages.create!(creator: @recipient, body: "Original 2", client_message_id: "activity-reply-source-2")
    suppressed_reply = @room.messages.create!(
      creator: @author,
      body: "Reply 2",
      reply_to_message: suppressed_source,
      client_message_id: "activity-reply-2"
    )
    assert_not ActivityItem.exists?(user: @recipient, source: suppressed_reply)
  end

  test "mention takes precedence when one message matches multiple activity reasons" do
    source = @room.messages.create!(creator: @recipient, body: "Original", client_message_id: "activity-priority-source")
    reply = @room.messages.create!(
      creator: @author,
      body: "Hey #{mention_attachment_for(:david)}",
      reply_to_message: source,
      client_message_id: "activity-priority"
    )

    assert_equal "mention", ActivityItem.find_by!(user: @recipient, source: reply).event_type
    assert_equal 1, ActivityItem.where(user: @recipient, source: reply).count
  end

  test "followed thread activity uses thread preferences" do
    thread = ChannelThread.create!(room: @room, creator: @author, name: "Activity thread")
    ThreadMembership.join!(thread, @author)
    ThreadMembership.join!(thread, @recipient).update!(involvement: "mentions")

    without_follow = thread.post_message!(creator: @author, attributes: { body: "Quiet update", client_message_id: "activity-thread-quiet" })
    assert_not ActivityItem.exists?(user: @recipient, source: without_follow)

    thread.memberships.find_by!(user: @recipient).update!(involvement: "everything")
    followed = thread.post_message!(creator: @author, attributes: { body: "Followed update", client_message_id: "activity-thread-followed" })
    assert_equal "thread_activity", ActivityItem.find_by!(user: @recipient, source: followed).event_type
  end

  test "work events notify followed thread members" do
    thread = ChannelThread.create!(room: @room, creator: @author, name: "Work activity thread")
    ThreadMembership.join!(thread, @author)
    ThreadMembership.join!(thread, @recipient).update!(involvement: "everything")

    thread.update_work!(actor: @author, work_status: "planned")

    event = thread.work_thread_events.ordered.first
    assert_equal "work_update", event.event_type
    assert_equal "work_update", ActivityItem.find_by!(user: @recipient, source: event).event_type
  end

  test "recording the same source twice is idempotent" do
    message = @room.messages.create!(
      creator: @author,
      body: "Hey #{mention_attachment_for(:david)}",
      client_message_id: "activity-idempotent"
    )
    ActivityItem.where(source: message).delete_all

    assert_difference -> { ActivityItem.where(user: @recipient, source: message).count }, 1 do
      2.times { ActivityItems::Recorder.record!(recipient: @recipient, source: message, event_type: "mention") }
    end
  end
end
