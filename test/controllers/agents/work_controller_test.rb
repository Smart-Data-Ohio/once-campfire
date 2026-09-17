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

  test "show includes links with pull request, event, and drive entries" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    thread = create_owned_thread!(name: "Linked work")
    pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 7)
    pull_request.update!(title: "Fix login", state: "open", html_url: "https://github.com/rails/rails/pull/7")
    thread.work_thread_links.create!(kind: :pull_request, github_pull_request: pull_request, created_by: users(:david))
    thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    drive_url = "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view"
    thread.work_thread_links.create!(kind: :drive_file, url: drive_url, title: "Q3 Planning", created_by: users(:david))

    get agents_work_thread_url(thread), headers: bearer_headers

    assert_response :success
    links = response.parsed_body["links"]
    assert_equal 3, links.size

    pr_entry = links.find { |entry| entry["kind"] == "pull_request" }
    assert_equal "https://github.com/rails/rails/pull/7", pr_entry["url"]
    assert_equal "Fix login", pr_entry["title"]
    assert_equal "rails", pr_entry.dig("pull_request", "owner")
    assert_equal "rails", pr_entry.dig("pull_request", "repo")
    assert_equal 7, pr_entry.dig("pull_request", "number")
    assert_equal "Fix login", pr_entry.dig("pull_request", "title")
    assert_equal "open", pr_entry.dig("pull_request", "state")
    assert_nil pr_entry["event"]

    event_entry = links.find { |entry| entry["kind"] == "event" }
    assert_equal room_event_path(@room, events(:watercooler_sync)), event_entry["url"]
    assert_equal "Watercooler sync", event_entry["title"]
    assert_nil event_entry["pull_request"]
    assert_equal events(:watercooler_sync).id, event_entry.dig("event", "id")
    assert_equal "Watercooler sync", event_entry.dig("event", "title")
    assert_equal events(:watercooler_sync).starts_at.utc.iso8601(3), event_entry.dig("event", "starts_at")
    assert_equal false, event_entry.dig("event", "cancelled")
    assert_equal room_event_path(@room, events(:watercooler_sync)), event_entry.dig("event", "url")

    drive_entry = links.find { |entry| entry["kind"] == "drive_file" }
    assert_equal drive_url, drive_entry["url"]
    assert_equal "Q3 Planning", drive_entry["title"]
    assert_nil drive_entry["pull_request"]
    assert_nil drive_entry["event"]
  end

  test "list includes links on owned threads" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    thread = create_owned_thread!(name: "Listed links")
    thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    create_owned_thread!(name: "Unlinked work")

    get agents_work_url, headers: bearer_headers

    assert_response :success
    rows = response.parsed_body.index_by { |row| row["id"] }
    assert_equal [ "event" ], rows[thread.id]["links"].map { |entry| entry["kind"] }
    assert_equal [], rows.values.find { |row| row["title"] == "Unlinked work" }["links"]
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

  test "list excludes rooms the agent no longer belongs to" do
    grant!(capability: "read_messages")
    grant!(capability: "post_messages", room: @room)
    kept = create_owned_thread!(name: "Kept work")

    designers = rooms(:designers)
    designers.memberships.grant_to(@bot)
    AgentGrant.create!(agent: @agent, room: designers, granted_by: users(:david), capability: "post_messages")
    orphaned = ChannelThread.create!(room: designers, creator: users(:david), name: "Orphaned work")
    ThreadMembership.join!(orphaned, users(:david))
    orphaned.update_work!(actor: users(:david), work_status: "planned", work_owner_id: @bot.id)
    designers.memberships.find_by!(user: @bot).destroy

    get agents_work_url, headers: bearer_headers

    assert_response :success
    assert_equal [ kept.id ], response.parsed_body.map { |row| row["id"] }
  end

  test "show and patch are 404 once the agent is no longer a room member" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Orphaned work")
    @room.memberships.find_by!(user: @bot).destroy

    get agents_work_thread_url(thread), headers: bearer_headers
    assert_response :not_found

    patch agents_work_thread_url(thread), params: { work_status: "done" }, headers: bearer_headers, as: :json
    assert_response :not_found
    assert_not_equal "done", thread.reload.work_status
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

  test "patch updates tags and run_url alongside the status" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Tagged work")

    patch agents_work_thread_url(thread), params: {
      work_status: "in_progress", tags: [ "API", "launch" ],
      run_url: "https://example.com/runs/3"
    }.to_json, headers: bearer_headers

    assert_response :success
    assert_equal "in_progress", thread.reload.work_status
    assert_equal %w[ api launch ], thread.tag_names
    assert_equal "https://example.com/runs/3", thread.run_url
    assert_equal %w[ api launch ], response.parsed_body["tags"]
    assert_equal "https://example.com/runs/3", response.parsed_body["run_url"]
  end

  test "patch updates tags alone in array and string forms" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Retagged work")

    patch agents_work_thread_url(thread),
      params: { tags: [ "API", "launch" ] }.to_json,
      headers: bearer_headers
    assert_response :success
    assert_equal %w[ api launch ], thread.reload.tag_names
    assert_equal "planned", thread.work_status

    patch agents_work_thread_url(thread),
      params: { tags: "backend, api" }.to_json,
      headers: bearer_headers
    assert_response :success
    assert_equal %w[ api backend ], thread.reload.tag_names

    patch agents_work_thread_url(thread),
      params: { tags: [] }.to_json,
      headers: bearer_headers
    assert_response :success
    assert_equal [], thread.reload.tag_names
  end

  test "patch updates run_url alone and blank clears it" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Linked run work")

    patch agents_work_thread_url(thread),
      params: { run_url: "https://example.com/runs/4" }.to_json,
      headers: bearer_headers
    assert_response :success
    assert_equal "https://example.com/runs/4", thread.reload.run_url

    patch agents_work_thread_url(thread),
      params: { run_url: "" }.to_json,
      headers: bearer_headers
    assert_response :success
    assert_nil thread.reload.run_url
  end

  test "patch rejects invalid tags and run_url with 422" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Validated tags work")

    invalid_bodies = [
      { tags: "one, two, three, four, five, six" },
      { tags: "Not a tag!" },
      { tags: "x" * 31 },
      { run_url: "http://example.com/runs/5" },
      { run_url: "https://example.com/#{"x" * 500}" }
    ]

    invalid_bodies.each do |body|
      patch agents_work_thread_url(thread), params: body.to_json, headers: bearer_headers
      assert_response :unprocessable_entity, "expected 422 for #{body.inspect}"
    end

    assert_equal [], thread.reload.tag_names
    assert_nil thread.run_url
  end

  test "patch cannot stop tracking with a blank status" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Tracked work")

    patch agents_work_thread_url(thread),
      params: { work_status: "" }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity
    assert_equal "planned", thread.reload.work_status
  end

  test "patch with only a note and no field is 422" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Noted work")

    patch agents_work_thread_url(thread),
      params: { note: "Nothing to attach this to" }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity
  end

  test "patch tags without manage_threads is 403" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    thread = create_owned_thread!(name: "Ungoverned tags")

    patch agents_work_thread_url(thread),
      params: { tags: "api" }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_equal [], thread.reload.tag_names
  end

  test "put replaces the pinned result and records the event" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Result work")

    assert_difference -> { thread.work_thread_events.where(event_type: "result_updated").count }, 1 do
      put agents_work_thread_url(thread) + "/result",
        params: { markdown: "## Shipped" }.to_json,
        headers: bearer_headers
    end

    assert_response :success
    assert_equal "## Shipped", thread.reload.result_markdown
    assert_equal @bot.id, thread.result_updated_by_id
    assert thread.result_updated_at.present?
    assert_equal "## Shipped", response.parsed_body["result"]
    assert response.parsed_body["result_updated_at"].present?

    event = thread.work_thread_events.ordered.first
    assert_equal "result_updated", event.event_type
    assert_equal @bot.id, event.actor_id
    assert_equal "## Shipped", event.metadata["excerpt"]
  end

  test "put result requires ownership and manage_threads" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    human_thread = create_human_thread!(name: "Not mine")

    put agents_work_thread_url(human_thread) + "/result",
      params: { markdown: "Hijacked" }.to_json,
      headers: bearer_headers
    assert_response :not_found
    assert_nil human_thread.reload.result_markdown

    AgentGrant.where(agent: @agent, capability: "manage_threads").sole.revoke!
    owned_thread = create_owned_thread!(name: "Ungoverned result")

    put agents_work_thread_url(owned_thread) + "/result",
      params: { markdown: "Denied" }.to_json,
      headers: bearer_headers
    assert_response :forbidden
    assert_equal "Forbidden: agent lacks manage_threads capability", response.parsed_body["error"]
    assert_nil owned_thread.reload.result_markdown
  end

  test "put result rejects missing markdown and overlong results with 422" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Capped result")

    put agents_work_thread_url(thread) + "/result",
      params: {}.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity

    put agents_work_thread_url(thread) + "/result",
      params: { markdown: "x" * 20_001 }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity

    put agents_work_thread_url(thread) + "/result",
      params: { markdown: "x" * 20_000 }.to_json,
      headers: bearer_headers
    assert_response :success
    assert_equal "x" * 20_000, thread.reload.result_markdown
  end

  test "put result with blank markdown clears" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Cleared result")
    thread.update_result!(actor: users(:david), markdown: "## Draft")

    assert_difference -> { thread.work_thread_events.where(event_type: "result_updated").count }, 1 do
      put agents_work_thread_url(thread) + "/result",
        params: { markdown: "" }.to_json,
        headers: bearer_headers
    end

    assert_response :success
    assert_nil thread.reload.result_markdown
  end

  test "put result with unchanged markdown writes nothing" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Stable result")

    put agents_work_thread_url(thread) + "/result",
      params: { markdown: "## Final" }.to_json,
      headers: bearer_headers
    assert_response :success

    assert_no_difference -> { thread.work_thread_events.count } do
      put agents_work_thread_url(thread) + "/result",
        params: { markdown: "## Final" }.to_json,
        headers: bearer_headers
    end
    assert_response :success
  end

  test "put result reaches the human inbox as work_update" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Inbox result")

    put agents_work_thread_url(thread) + "/result",
      params: { markdown: "## Done" }.to_json,
      headers: bearer_headers
    assert_response :success

    event = thread.work_thread_events.ordered.first
    item = ActivityItem.find_by!(user: users(:david), source: event)
    assert_equal "work_update", item.event_type
  end

  test "put result is Bearer-only" do
    grant!(capability: "read_messages", room: @room)
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "manage_threads", room: @room)
    thread = create_owned_thread!(name: "Session result")

    sign_in :david
    put agents_work_thread_url(thread) + "/result",
      params: { markdown: "Human" }
    assert_response :forbidden
    assert_nil thread.reload.result_markdown
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

    put agents_work_thread_url(thread) + "/result",
      params: { markdown: "Revoked" }.to_json,
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
