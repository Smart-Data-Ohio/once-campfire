require "test_helper"

class ChannelThreadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @room = rooms(:designers)
    @creator = users(:jz)
    @thread = ChannelThread.create!(room: @room, creator: @creator, name: "Design discussion")
    ThreadMembership.join!(@thread, @creator)
  end

  test "creation accepts nested thread message parameters and joins only the creator" do
    sign_in :jz

    assert_difference -> { ChannelThread.count }, 1 do
      assert_difference -> { Message.thread_messages.count }, 1 do
        post room_threads_url(@room, format: :json), params: {
          thread: { name: "Nested start", message: { markdown_source: "First thread post", client_message_id: "nested-thread-start" } }
        }
      end
    end

    assert_response :created
    created = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    assert_equal [ users(:jz).id ], created.memberships.pluck(:user_id)
    assert_equal "First thread post", created.messages.sole.plain_text_body
  end

  test "creator settings, joined-member reopening, and moderator lifecycle powers stay distinct" do
    joined_user = users(:kevin)
    ThreadMembership.join!(@thread, joined_user)

    sign_in :jz
    patch room_thread_url(@room, @thread, format: :json), params: { thread: { name: "Renamed", auto_archive_after_minutes: 1_440 } }
    assert_response :success
    assert_equal "Renamed", @thread.reload.name

    patch room_thread_url(@room, @thread, format: :json), params: { thread: { status: "closed" } }
    assert_response :success
    assert_predicate @thread.reload, :closed?

    sign_in :kevin
    patch room_thread_url(@room, @thread, format: :json), params: { thread: { status: "active" } }
    assert_response :success
    assert_predicate @thread.reload, :active?

    patch room_thread_url(@room, @thread, format: :json), params: { thread: { status: "locked" } }
    assert_response :forbidden

    sign_in :david
    patch room_thread_url(@room, @thread, format: :json), params: { thread: { status: "locked" } }
    assert_response :success
    assert_predicate @thread.reload, :locked?

    sign_in :jz
    patch room_thread_url(@room, @thread, format: :json), params: { thread: { status: "active" } }
    assert_response :forbidden

    sign_in :david
    delete room_thread_url(@room, @thread, format: :json)
    assert_response :no_content
  end

  test "browsing does not join and stale active threads archive on the thread surface" do
    @thread.update_columns(last_activity_at: 2.hours.ago, auto_archive_after_minutes: 60)
    assert_not @thread.memberships.exists?(user: users(:kevin))

    sign_in :kevin
    get room_threads_url(@room, state: "all", format: :json)

    assert_response :success
    assert_predicate @thread.reload, :closed?
    assert_not @thread.memberships.exists?(user: users(:kevin))
  end

  test "joining accepts only thread notification preferences and preserves an existing preference when omitted" do
    sign_in :kevin

    assert_no_difference -> { ThreadMembership.count } do
      post join_room_thread_url(@room, @thread, format: :json), params: { involvement: "loud" }
    end
    assert_response :unprocessable_content
    assert_not @thread.memberships.exists?(user: users(:kevin))

    post join_room_thread_url(@room, @thread, format: :json), params: { involvement: "everything" }
    assert_response :success
    membership = @thread.memberships.find_by!(user: users(:kevin))
    assert_equal "everything", membership.involvement
    membership_id = membership.id

    post join_room_thread_url(@room, @thread, format: :json)
    assert_response :success
    membership.reload
    assert_equal membership_id, membership.id
    assert_equal "everything", membership.involvement
  end

  test "closed state contains locked threads and direct rooms reject thread creation" do
    @thread.lock_conversation!
    sign_in :jz
    get room_threads_url(@room, state: "closed", format: :json)
    assert_response :success
    assert_includes response.parsed_body.fetch("threads").pluck("id"), @thread.id

    direct = rooms(:david_and_kevin)
    sign_in :david
    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(direct, format: :json), params: { thread: { name: "Not permitted" } }
    end
    assert_response :forbidden
  end

  test "a deleted starter is represented explicitly so open clients clear its preview" do
    parent = messages(:third)
    @thread.update!(parent_message: parent)
    parent.destroy!
    sign_in :jz

    get room_thread_url(@room, @thread, format: :json)

    assert_response :success
    payload = response.parsed_body
    assert payload.fetch("thread").key?("parent_message_id")
    assert_nil payload.dig("thread", "parent_message_id")
    assert_nil payload.fetch("parent_message")
    assert_not_includes response.body, "Third time's a charm."
  end

  test "content anchors only a message in the requested thread" do
    first = @thread.post_message!(creator: @creator, attributes: { markdown_source: "First", client_message_id: "content-first" })
    second = @thread.post_message!(creator: @creator, attributes: { markdown_source: "Second", client_message_id: "content-second" })
    other_thread = ChannelThread.create!(room: @room, creator: @creator, name: "Other thread")
    ThreadMembership.join!(other_thread, @creator)
    other_message = other_thread.post_message!(creator: @creator, attributes: { markdown_source: "Elsewhere", client_message_id: "other-content" })

    sign_in :jz
    get content_room_thread_url(@room, @thread, message_id: first.id)
    assert_response :success
    assert_equal "false", response.headers["X-Thread-Content-At-Latest"]
    assert_select "#message_#{first.client_message_id}", 1
    assert_select "#message_#{second.client_message_id}", 1
    assert_select "#message_#{other_message.client_message_id}", 0

    assert_raises ActiveRecord::RecordNotFound do
      get content_room_thread_url(@room, @thread, message_id: other_message.id)
    end
  end
end
