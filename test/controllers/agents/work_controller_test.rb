require "test_helper"

class Agents::WorkControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "list shows only owned threads newest first with the work fields" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    older = create_owned_thread!(name: "Older work")
    newer = create_owned_thread!(name: "Newer work")
    older.update_columns(updated_at: 2.hours.ago)
    newer.update_columns(updated_at: 1.hour.ago)
    create_human_thread!(name: "Human work")

    get agents_work_url, headers: bearer_headers

    assert_response :success
    assert_equal [ newer.id, older.id ], response.parsed_body.map { |row| row["id"] }
    row = response.parsed_body.first
    assert_equal @room.id, row["room_id"]
    assert_equal "Newer work", row["title"]
    assert_equal "planned", row["work_status"]
    assert_equal room_path(@room, thread: newer.id), row["url"]
    assert row["updated_at"].present?
  end

  test "list is capped at 100 threads" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    101.times { |index| create_owned_thread!(name: "Capped work #{index}") }

    get agents_work_url, headers: bearer_headers

    assert_response :success
    assert_equal 100, response.parsed_body.size
  end

  test "list only includes rooms where the agent holds read_messages" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    readable = create_owned_thread!(name: "Readable work")

    designers = rooms(:designers)
    designers.memberships.grant_to(@bot)
    AgentGrant.create!(agent: @agent, room: designers, granted_by: users(:david), capability: "post_messages")
    hidden = ChannelThread.create!(room: designers, creator: users(:david), name: "Unreadable work")
    ThreadMembership.join!(hidden, users(:david))
    hidden.update_work!(actor: users(:david), work_status: "planned", work_owner_id: @bot.id)

    get agents_work_url, headers: bearer_headers

    assert_response :success
    assert_equal [ readable.id ], response.parsed_body.map { |row| row["id"] }
    assert_not_includes response.parsed_body.map { |row| row["id"] }, hidden.id
  end

  test "list is Bearer-only and empty without owned threads" do
    grant!(capability: "read_messages", room: @room)

    get agents_work_url, headers: bearer_headers
    assert_response :success
    assert_equal [], response.parsed_body

    sign_in :david
    get agents_work_url
    assert_response :forbidden
  end

  test "show returns one owned thread" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    thread = create_owned_thread!(name: "Show work")

    get agents_work_thread_url(thread), headers: bearer_headers

    assert_response :success
    assert_equal thread.id, response.parsed_body["id"]
    assert_equal "Show work", response.parsed_body["title"]
    assert_equal "planned", response.parsed_body["work_status"]
  end

  test "show is 404 for threads the agent does not own" do
    grant!(capability: "read_messages", room: @room)
    human_thread = create_human_thread!(name: "Not mine")

    get agents_work_thread_url(human_thread), headers: bearer_headers
    assert_response :not_found

    get agents_work_thread_url(123_456), headers: bearer_headers
    assert_response :not_found
  end

  test "patch changes the status and records the note in work history" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Patch work")

    assert_difference -> { thread.work_thread_events.count }, 1 do
      patch agents_work_thread_url(thread),
        params: { work_status: "in_progress", note: "Digging into the bug" }.to_json,
        headers: bearer_headers
    end

    assert_response :success
    assert_equal "in_progress", response.parsed_body["work_status"]
    assert_equal "in_progress", thread.reload.work_status

    event = thread.work_thread_events.ordered.first
    assert_equal "work_update", event.event_type
    assert_equal @bot.id, event.actor_id
    assert_equal "Digging into the bug", event.note

    sign_in :david
    get room_thread_url(@room, thread, format: :json)
    assert_response :success
    history = response.parsed_body.dig("thread", "work_history")
    assert_equal "Digging into the bug", history.first["note"]

    get room_thread_url(@room, thread)
    assert_response :success
    assert_match "Digging into the bug", response.body
  end

  test "patch is 404 for threads the agent does not own" do
    grant!(capability: "manage_threads", room: @room)
    human_thread = create_human_thread!(name: "Not mine")

    patch agents_work_thread_url(human_thread),
      params: { work_status: "in_progress" }.to_json,
      headers: bearer_headers

    assert_response :not_found
    assert_equal "planned", human_thread.reload.work_status
  end

  test "patch is 403 without manage_threads in the thread room" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    thread = create_owned_thread!(name: "Ungoverned work")

    patch agents_work_thread_url(thread),
      params: { work_status: "in_progress" }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks manage_threads capability", response.parsed_body["error"]
    assert_equal "planned", thread.reload.work_status
  end

  test "patch is 403 when manage_threads covers another room" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: rooms(:designers))
    thread = create_owned_thread!(name: "Scoped work")

    patch agents_work_thread_url(thread),
      params: { work_status: "in_progress" }.to_json,
      headers: bearer_headers

    assert_response :forbidden
  end

  test "patch rejects invalid statuses and long notes with 422" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Validated work")

    patch agents_work_thread_url(thread),
      params: { work_status: "shipped" }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity

    patch agents_work_thread_url(thread),
      params: { work_status: "in_progress", note: "x" * 501 }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity

    patch agents_work_thread_url(thread), params: {}.to_json, headers: bearer_headers
    assert_response :unprocessable_entity

    assert_equal "planned", thread.reload.work_status
  end

  test "patch cannot reassign, convert, or stop tracking" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Guarded work")

    patch agents_work_thread_url(thread),
      params: { work_status: "in_progress", work_owner_id: users(:jason).id }.to_json,
      headers: bearer_headers

    assert_response :success
    assert_equal @bot.id, thread.reload.work_owner_id
    assert_equal "in_progress", thread.work_status
  end

  test "a revoked credential is 401" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    thread = create_owned_thread!(name: "Revoked work")
    agent_credentials(:bender_main).revoke!

    get agents_work_url, headers: bearer_headers
    assert_response :unauthorized

    get agents_work_thread_url(thread), headers: bearer_headers
    assert_response :unauthorized

    patch agents_work_thread_url(thread),
      params: { work_status: "in_progress" }.to_json,
      headers: bearer_headers
    assert_response :unauthorized
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end

    def create_owned_thread!(name:)
      thread = ChannelThread.create!(room: @room, creator: users(:david), name: name)
      ThreadMembership.join!(thread, users(:david))
      thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: @bot.id)
      thread
    end

    def create_human_thread!(name:)
      thread = ChannelThread.create!(room: @room, creator: users(:david), name: name)
      ThreadMembership.join!(thread, users(:david))
      thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: users(:jason).id)
      thread
    end
end
