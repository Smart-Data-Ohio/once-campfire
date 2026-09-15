require "test_helper"

class ChannelThreadMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @room = rooms(:designers)
    @thread = ChannelThread.create!(room: @room, creator: users(:jz), name: "Thread messages")
    ThreadMembership.join!(@thread, users(:jz))
    @message = @thread.post_message!(creator: users(:jz), attributes: { markdown_source: "Original", client_message_id: "thread-original" })
  end

  test "a post joins and reopens an unlocked closed thread atomically" do
    @thread.close!
    assert_not @thread.memberships.exists?(user: users(:kevin))
    sign_in :kevin

    post room_thread_messages_url(@room, @thread, format: :json), params: {
      message: { markdown_source: "Joined reply", client_message_id: "joined-reply" }
    }

    assert_response :created
    assert_predicate @thread.reload, :active?
    assert @thread.memberships.exists?(user: users(:kevin))
    assert_equal "Joined reply", @thread.messages.order(:id).last.plain_text_body
  end

  test "locked threads block every edit and post while delete stays author-or-admin" do
    @thread.lock_conversation!
    sign_in :jz

    patch room_thread_message_url(@room, @thread, @message, format: :json), params: { message: { markdown_source: "Edited" } }
    assert_response :forbidden
    assert_equal "Original", @message.reload.plain_text_body

    post room_thread_messages_url(@room, @thread, format: :json), params: { message: { markdown_source: "Blocked", client_message_id: "blocked-thread-post" } }
    assert_response :forbidden

    get actions_room_thread_message_url(@room, @thread, @message, format: :json)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not response.parsed_body.dig("actions", "can_edit")

    sign_in :david
    patch room_thread_message_url(@room, @thread, @message, format: :json), params: { message: { markdown_source: "Admin blocked" } }
    assert_response :forbidden

    delete room_thread_message_url(@room, @thread, @message, format: :json)
    assert_response :no_content
  end

  test "thread unread state changes for every joined user regardless of preference" do
    nothing = users(:kevin)
    everything = users(:jason)
    ThreadMembership.join!(@thread, nothing).update!(involvement: "nothing")
    ThreadMembership.join!(@thread, everything).update!(involvement: "everything")

    @thread.post_message!(creator: users(:jz), attributes: { markdown_source: "Unread all", client_message_id: "unread-all" })

    assert @thread.memberships.find_by!(user: nothing).unread?
    assert @thread.memberships.find_by!(user: everything).unread?
  end

  test "nested HTML message URL redirects into the parent room shell" do
    sign_in :jz
    get room_thread_message_url(@room, @thread, @message)

    assert_redirected_to room_url(@room, thread: @thread.id, message_id: @message.id)
  end
end
