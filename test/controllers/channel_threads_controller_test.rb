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

  test "converts a thread to work, assigns an eligible owner, and keeps an audit trail" do
    message = @thread.post_message!(creator: @creator, attributes: { markdown_source: "Keep this history", client_message_id: "work-history" })
    sign_in :jz

    assert_difference -> { WorkThreadEvent.count }, 1 do
      patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_status: "planned" } }
    end
    assert_response :success
    assert_equal true, response.parsed_body.dig("thread", "work")
    assert_equal "planned", response.parsed_body.dig("thread", "work_status")

    assert_difference -> { WorkThreadEvent.count }, 1 do
      patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_owner_id: users(:kevin).id } }
    end
    assert_response :success
    assert_equal users(:kevin).id, response.parsed_body.dig("thread", "work_owner", "id")

    event = @thread.work_thread_events.ordered.first
    assert_equal "work_assignment", event.event_type
    assert_nil event.from_owner_id
    assert_equal users(:kevin).id, event.to_owner_id
    assert_equal "planned", event.from_status
    assert_equal "planned", event.to_status
    assert_equal users(:jz).id, event.actor_id
    assert_equal message.id, @thread.messages.find_by!(client_message_id: "work-history").id
  end

  test "work owner must be an active human parent-room member and a revoked owner stays visible as unavailable" do
    sign_in :jz
    patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_status: "planned", work_owner_id: users(:kevin).id } }
    assert_response :success

    assert_no_difference -> { WorkThreadEvent.count } do
      patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_owner_id: users(:bender).id } }
    end
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "active human member"
    assert_equal users(:kevin).id, @thread.reload.work_owner_id

    users(:kevin).deactivate
    assert_not @thread.reload.work_owner_active?

    get room_thread_url(@room, @thread, format: :json)
    assert_response :success
    assert_equal false, response.parsed_body.dig("thread", "work_owner", "active")
    assert_equal "Kevin", response.parsed_body.dig("thread", "work_owner", "name")

    patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_owner_id: "" } }
    assert_response :success
    assert_nil @thread.reload.work_owner_id
  end

  test "assigned owner can change work status but cannot reassign it" do
    @thread.update!(work_status: "planned", work_owner_id: users(:kevin).id)
    sign_in :kevin

    assert_difference -> { WorkThreadEvent.count }, 1 do
      patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_status: "in_progress" } }
    end
    assert_response :success
    assert_equal "in_progress", @thread.reload.work_status

    patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_owner_id: users(:jz).id } }
    assert_response :forbidden
    assert_equal users(:kevin).id, @thread.reload.work_owner_id

    patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_status: "" } }
    assert_response :forbidden
    assert_equal "in_progress", @thread.reload.work_status
  end

  test "only a thread manager can remove work tracking" do
    @thread.update!(work_status: "planned", work_owner_id: users(:kevin).id)
    sign_in :jz

    assert_difference -> { WorkThreadEvent.count }, 1 do
      patch room_thread_url(@room, @thread, format: :json), params: { thread: { work_status: "", work_owner_id: "" } }
    end
    assert_response :success
    assert_nil @thread.reload.work_status
    assert_nil @thread.work_owner_id
  end

  test "the work model also protects conversion when the owner field is omitted" do
    @thread.update!(work_status: "planned", work_owner_id: users(:kevin).id)

    assert_raises ChannelThread::WorkUpdateForbidden do
      @thread.update_work!(actor: users(:kevin), work_status: nil)
    end

    assert_equal "planned", @thread.reload.work_status
    assert_equal users(:kevin).id, @thread.work_owner_id
  end

  test "work status updates from separate stale instances produce one event per real change" do
    @thread.update!(work_status: "planned")
    first = ChannelThread.find(@thread.id)
    second = ChannelThread.find(@thread.id)
    actor = users(:jz)

    assert_difference -> { WorkThreadEvent.count }, 2 do
      first.update_work!(actor:, work_status: "in_progress")
      second.update_work!(actor:, work_status: "blocked")
    end

    assert_equal "blocked", @thread.reload.work_status
    assert_equal [ "blocked", "in_progress" ], @thread.work_thread_events.ordered.limit(2).pluck(:to_status)
  end

  test "ordinary thread fields remain separate from work tracking" do
    sign_in :jz
    get room_thread_url(@room, @thread, format: :json)

    assert_response :success
    payload = response.parsed_body.fetch("thread")
    assert_equal false, payload.fetch("work")
    assert_nil payload.fetch("work_status")
    assert_nil payload.fetch("work_owner")
    assert_empty @thread.work_thread_events
  end
end
