require "test_helper"

class Agents::PostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    @board = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:kevin) ])
    @board.memberships.grant_to(@bot)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "creates a post with defaults and returns the work payload" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    assert_difference -> { ChannelThread.count }, 1 do
      assert_difference -> { Message.thread_messages.count }, 1 do
        post room_agent_posts_url(@board),
          params: { title: "Ship the launch", body: "Everything goes out Friday." }.to_json,
          headers: bearer_headers
      end
    end

    assert_response :created
    post = ChannelThread.ordered.first
    assert_equal "Ship the launch", post.name
    assert_equal "in_progress", post.work_status
    assert_equal @bot.id, post.work_owner_id
    assert_equal @bot.id, post.creator_id
    assert_equal "Everything goes out Friday.", post.messages.sole.plain_text_body
    assert_equal @bot.id, post.messages.sole.creator_id

    payload = response.parsed_body
    assert_equal post.id, payload["id"]
    assert_equal @board.id, payload["room_id"]
    assert_equal @board.id, payload["board_id"]
    assert_equal "Launch", payload["board_name"]
    assert_equal "Ship the launch", payload["title"]
    assert_equal "in_progress", payload["work_status"]
    assert_equal({ "id" => @bot.id, "name" => "Bender Bot", "agent" => true }, payload["owner"])
    assert_equal [], payload["tags"]
    assert_nil payload["result"]
    assert_nil payload["result_updated_at"]
    assert_nil payload["run_url"]
    assert_equal room_path(@board, thread: post.id), payload["url"]
    assert payload["updated_at"].present?
    assert_equal [], payload["links"]
  end

  test "creates a post with tags, status, run_url, and a human owner" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    post room_agent_posts_url(@board), params: {
      title: "Launch checklist", body: "The brief.", tags: "Launch, api",
      work_status: "planned", run_url: "https://example.com/runs/7",
      owner_id: users(:kevin).id
    }.to_json, headers: bearer_headers

    assert_response :created
    post = ChannelThread.ordered.first
    assert_equal "planned", post.work_status
    assert_equal users(:kevin).id, post.work_owner_id
    assert_equal %w[ api launch ], post.tag_names
    assert_equal "https://example.com/runs/7", post.run_url
    assert_equal %w[ api launch ], response.parsed_body["tags"]
    assert_equal "https://example.com/runs/7", response.parsed_body["run_url"]
    assert_equal({ "id" => users(:kevin).id, "name" => "Kevin", "agent" => false },
      response.parsed_body["owner"])

    event = post.work_thread_events.ordered.first
    assert_equal "work_assignment", event.event_type
    assert_nil event.from_owner_id
    assert_equal users(:kevin).id, event.to_owner_id
    assert_equal @bot.id, event.actor_id
    assert_equal 1, ActivityItem.where(user: users(:kevin), event_type: "work_assignment").count
  end

  test "creates a post with an array of tags" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    post room_agent_posts_url(@board),
      params: { title: "Tagged", tags: [ "API", "launch" ] }.to_json,
      headers: bearer_headers

    assert_response :created
    assert_equal %w[ api launch ], ChannelThread.ordered.first.tag_names
  end

  test "creates a post owned by another agent through the assignment path" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)
    other = create_agent_in(@board, name: "Board Worker")
    AgentGrant.create!(agent: other, room: @board, granted_by: users(:david), capability: "post_messages")

    assert_difference -> { other.agent_events.where(event_type: "work_assigned").count }, 1 do
      post room_agent_posts_url(@board),
        params: { title: "Agent post", owner_id: other.user_id }.to_json,
        headers: bearer_headers
    end

    assert_response :created
    post = ChannelThread.ordered.first
    assert_equal other.user_id, post.work_owner_id
    assert_equal "work_assignment", post.work_thread_events.ordered.first.event_type
  end

  test "owner defaults to the agent itself, like a blank owner_id" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    post room_agent_posts_url(@board),
      params: { title: "Default owner" }.to_json,
      headers: bearer_headers
    assert_response :created
    assert_equal @bot.id, ChannelThread.ordered.first.work_owner_id

    post room_agent_posts_url(@board),
      params: { title: "Blank owner", owner_id: "" }.to_json,
      headers: bearer_headers
    assert_response :created
    assert_equal @bot.id, ChannelThread.ordered.first.work_owner_id

    post room_agent_posts_url(@board),
      params: { title: "Null owner", owner_id: nil }.to_json,
      headers: bearer_headers
    assert_response :created
    assert_equal @bot.id, ChannelThread.ordered.first.work_owner_id
  end

  test "a first message writes the posted ledger row and notifies the board" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)
    @board.memberships.find_by!(user: users(:kevin)).update!(involvement: "everything")

    post room_agent_posts_url(@board),
      params: { title: "Notified", body: "Read me." }.to_json,
      headers: bearer_headers

    assert_response :created
    post = ChannelThread.ordered.first
    posted = @agent.agent_events.where(event_type: "posted").last
    assert_equal post.messages.sole.id, posted.message_id
    assert_equal post.id, posted.metadata["thread_id"]
    assert_equal 1, ActivityItem.where(user: users(:kevin), event_type: "thread_activity").count
  end

  test "a messageless post still assigns the owner without a posted row" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    assert_no_difference -> { @agent.agent_events.where(event_type: "posted").count } do
      post room_agent_posts_url(@board),
        params: { title: "Quiet post", owner_id: users(:kevin).id }.to_json,
        headers: bearer_headers
    end

    assert_response :created
    post = ChannelThread.ordered.first
    assert_empty post.messages
    assert_equal "work_assignment", post.work_thread_events.ordered.first.event_type
    assert_equal 1, ActivityItem.where(user: users(:kevin), event_type: "work_assignment").count
    assert_empty ActivityItem.where(user: users(:kevin), event_type: "thread_activity")
  end

  test "rejects invalid posts with 422" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)
    suspended = create_agent_in(@board, name: "Suspended Owner")
    suspended.suspend!

    invalid_bodies = [
      {},
      { title: "" },
      { title: "x" * 101 },
      { title: "Bad status", work_status: "shipping" },
      { title: "Many tags", tags: "one, two, three, four, five, six" },
      { title: "Bad tag", tags: "Not a tag!" },
      { title: "Long tag", tags: "x" * 31 },
      { title: "Bad run", run_url: "http://example.com/runs/7" },
      { title: "Bad owner", owner_id: users(:jason).id },
      { title: "Missing owner", owner_id: 999_999 },
      { title: "Garbage owner", owner_id: "abc" },
      { title: "Suspended owner", owner_id: suspended.user_id }
    ]

    invalid_bodies.each do |body|
      assert_no_difference -> { ChannelThread.count }, "expected no post for #{body.inspect}" do
        post room_agent_posts_url(@board), params: body.to_json, headers: bearer_headers
      end
      assert_response :unprocessable_entity, "expected 422 for #{body.inspect}"
      assert response.parsed_body["error"].present?
    end
  end

  test "requires post_messages and manage_threads in the board" do
    post room_agent_posts_url(@board),
      params: { title: "Legacy post" }.to_json,
      headers: bearer_headers
    assert_response :forbidden
    assert_equal "Forbidden: agent lacks manage_threads capability", response.parsed_body["error"]

    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    post room_agent_posts_url(@board),
      params: { title: "Ungoverned post" }.to_json,
      headers: bearer_headers
    assert_response :forbidden
    assert_equal "Forbidden: agent lacks manage_threads capability", response.parsed_body["error"]

    AgentGrant.create!(agent: @agent, room: rooms(:designers), granted_by: users(:david), capability: "manage_threads")
    post room_agent_posts_url(@board),
      params: { title: "Scoped post" }.to_json,
      headers: bearer_headers
    assert_response :forbidden
  end

  test "requires post_messages even with manage_threads" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    post room_agent_posts_url(@board),
      params: { title: "Unpostable" }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks post_messages capability", response.parsed_body["error"]
  end

  test "is 404 for rooms the agent is not a member of" do
    grant!(capability: "post_messages")
    grant!(capability: "manage_threads")
    stranger_board = Rooms::Board.create_for({ name: "Secret", creator: users(:david) },
      users: [ users(:david) ])

    post room_agent_posts_url(stranger_board),
      params: { title: "Intruder" }.to_json,
      headers: bearer_headers
    assert_response :not_found

    get room_agent_posts_url(stranger_board), headers: bearer_headers
    assert_response :not_found
  end

  test "is 422 for non-board rooms" do
    grant!(capability: "read_messages", room: rooms(:watercooler))
    grant!(capability: "post_messages", room: rooms(:watercooler))
    grant!(capability: "manage_threads", room: rooms(:watercooler))

    post room_agent_posts_url(rooms(:watercooler)),
      params: { title: "Channel post" }.to_json,
      headers: bearer_headers
    assert_response :unprocessable_entity
    assert_equal "Room is not a board", response.parsed_body["error"]

    get room_agent_posts_url(rooms(:watercooler)), headers: bearer_headers
    assert_response :unprocessable_entity
    assert_equal "Room is not a board", response.parsed_body["error"]
  end

  test "rejects session and bot-key requests" do
    sign_in :david
    post room_agent_posts_url(@board), params: { title: "Human post" }
    assert_response :forbidden
    assert_equal bearer_token_error, response.parsed_body["error"]

    get room_agent_posts_url(@board)
    assert_response :forbidden
    delete session_url

    post room_agent_posts_url(@board, bot_key: @bot.bot_key),
      params: { title: "Legacy post" }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "lists the board's open posts newest activity first" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    older = create_post!(name: "Older", work_status: "planned")
    newer = create_post!(name: "Newer", work_status: "in_progress")
    blocked = create_post!(name: "Blocked", work_status: "blocked")
    done = create_post!(name: "Finished", work_status: "done")
    older.update_columns(last_activity_at: 3.hours.ago, updated_at: 3.hours.ago)
    newer.update_columns(last_activity_at: 2.hours.ago, updated_at: 2.hours.ago)
    blocked.update_columns(last_activity_at: 1.hour.ago, updated_at: 1.hour.ago)

    get room_agent_posts_url(@board), headers: bearer_headers

    assert_response :success
    assert_equal [ blocked.id, newer.id, older.id ], response.parsed_body.map { |row| row["id"] }
    assert_not_includes response.parsed_body.map { |row| row["id"] }, done.id

    row = response.parsed_body.first
    assert_equal @board.id, row["board_id"]
    assert_equal "Launch", row["board_name"]
    assert_equal "Blocked", row["title"]
    assert_equal({ "id" => @bot.id, "name" => "Bender Bot", "agent" => true }, row["owner"])
  end

  test "a reply moves the post to the top of the list" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    older = create_post!(name: "Older")
    newer = create_post!(name: "Newer")
    older.update_columns(last_activity_at: 3.hours.ago)
    newer.update_columns(last_activity_at: 2.hours.ago)

    older.post_message!(creator: users(:david), attributes: { markdown_source: "Bump" })

    get room_agent_posts_url(@board), headers: bearer_headers

    assert_response :success
    assert_equal [ older.id, newer.id ], response.parsed_body.map { |row| row["id"] }
  end

  test "lists by single status, done, and all" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    planned = create_post!(name: "Planned", work_status: "planned")
    progressing = create_post!(name: "Progressing", work_status: "in_progress")
    finished = create_post!(name: "Finished", work_status: "done")

    get room_agent_posts_url(@board, status: "planned"), headers: bearer_headers
    assert_equal [ planned.id ], response.parsed_body.map { |row| row["id"] }

    get room_agent_posts_url(@board, status: "done"), headers: bearer_headers
    assert_equal [ finished.id ], response.parsed_body.map { |row| row["id"] }

    get room_agent_posts_url(@board, status: "all"), headers: bearer_headers
    assert_equal [ finished.id, progressing.id, planned.id ].sort,
      response.parsed_body.map { |row| row["id"] }.sort

    get room_agent_posts_url(@board, status: "open"), headers: bearer_headers
    assert_equal [ progressing.id, planned.id ].sort,
      response.parsed_body.map { |row| row["id"] }.sort
  end

  test "rejects invalid list filters with 422" do
    grant!(capability: "read_messages", room: @board)

    get room_agent_posts_url(@board, status: "shipping"), headers: bearer_headers
    assert_response :unprocessable_entity

    get room_agent_posts_url(@board, owner: "everyone"), headers: bearer_headers
    assert_response :unprocessable_entity
  end

  test "lists by owner me, agents, and id" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    mine = create_post!(name: "Mine")
    other_agent = create_agent_in(@board, name: "List Worker")
    AgentGrant.create!(agent: other_agent, room: @board, granted_by: users(:david), capability: "post_messages")
    theirs = create_post!(name: "Theirs", owner: other_agent.user)
    humans = create_post!(name: "Humans", owner: users(:kevin))

    get room_agent_posts_url(@board, owner: "me"), headers: bearer_headers
    assert_equal [ mine.id ], response.parsed_body.map { |row| row["id"] }

    get room_agent_posts_url(@board, owner: "agents"), headers: bearer_headers
    assert_equal [ mine.id, theirs.id ].sort, response.parsed_body.map { |row| row["id"] }.sort

    get room_agent_posts_url(@board, owner: users(:kevin).id), headers: bearer_headers
    assert_equal [ humans.id ], response.parsed_body.map { |row| row["id"] }

    get room_agent_posts_url(@board, owner: 999_999), headers: bearer_headers
    assert_equal [], response.parsed_body
  end

  test "lists by tag" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    tagged = create_post!(name: "Tagged", tags: "api, launch")
    create_post!(name: "Untagged")

    get room_agent_posts_url(@board, tag: "API"), headers: bearer_headers
    assert_equal [ tagged.id ], response.parsed_body.map { |row| row["id"] }

    get room_agent_posts_url(@board, tag: "missing"), headers: bearer_headers
    assert_equal [], response.parsed_body
  end

  test "caps the list at 100 posts" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    101.times { |index| create_post!(name: "Capped #{index}") }

    get room_agent_posts_url(@board), headers: bearer_headers

    assert_response :success
    assert_equal 100, response.parsed_body.size
  end

  test "listing requires read_messages" do
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    get room_agent_posts_url(@board), headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks read_messages capability", response.parsed_body["error"]
  end

  test "a legacy agent without grants can list but cannot create" do
    assert @agent.legacy_capabilities?
    create_post!(name: "Legacy visible")

    get room_agent_posts_url(@board), headers: bearer_headers
    assert_response :success
    assert_equal [ "Legacy visible" ], response.parsed_body.map { |row| row["title"] }

    post room_agent_posts_url(@board),
      params: { title: "Legacy post" }.to_json,
      headers: bearer_headers
    assert_response :forbidden
  end

  test "listing is 404 once the agent leaves the board" do
    grant!(capability: "read_messages", room: @board)
    @board.memberships.find_by!(user: @bot).destroy

    get room_agent_posts_url(@board), headers: bearer_headers
    assert_response :not_found
  end

  test "creation, listing, and event delivery share one work payload" do
    grant!(capability: "read_messages", room: @board)
    grant!(capability: "post_messages", room: @board)
    grant!(capability: "manage_threads", room: @board)

    post room_agent_posts_url(@board), params: {
      title: "Shared payload", body: "The brief.", tags: "api",
      run_url: "https://example.com/runs/9"
    }.to_json, headers: bearer_headers
    assert_response :created
    created_payload = response.parsed_body

    get agents_work_url, headers: bearer_headers
    assert_response :success
    listed_payload = response.parsed_body.find { |row| row["id"] == created_payload["id"] }
    assert_equal created_payload, listed_payload

    get agents_events_url, headers: bearer_headers
    assert_response :success
    event_row = response.parsed_body.find { |entry| entry["event_type"] == "work_assigned" }
    work_key = event_row["work"]
    assert_equal created_payload["id"], work_key["thread_id"]
    assert_equal created_payload["work_status"], work_key["status"]
    assert_equal "Bender Bot", work_key["assigned_by"]
    assert_equal created_payload, work_key.except("thread_id", "status", "assigned_by")
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end

    def bearer_token_error
      [ "Forbidden: Bearer", "agent", "token required" ].join(" ")
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      room.memberships.grant_to(bot)
      agent
    end

    def create_post!(name:, work_status: "planned", owner: @bot, tags: nil)
      post = ChannelThread.create_board_post!(
        room: @board, creator: users(:david), name: name,
        work_status: work_status, owner_id: owner&.id, tags: tags
      )
      post
    end
end
