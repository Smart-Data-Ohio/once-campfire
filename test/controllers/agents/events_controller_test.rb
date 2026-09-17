require "test_helper"

class Agents::EventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
  end

  test "polling returns only the agent's own rows" do
    other_agent = create_agent_in(@room, name: "Poll Bot Other")

    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-own"
    )
    @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[#{other_agent.user.name}]",
      client_message_id: "poll-other"
    )

    get agents_events_url, headers: bearer_headers

    assert_response :success
    ids = response.parsed_body.map { |row| row["id"] }
    assert_equal @agent.agent_events.deliverable.pluck(:id).sort, ids.sort
    assert_not_includes ids, other_agent.agent_events.deliverable.last.id
  end

  test "polling resolves the message payload at query time" do
    message = @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-payload"
    )

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.first
    assert_equal "mention", row["event_type"]
    assert_equal message.id, row.dig("message", "id")
    assert_equal users(:david).id, row.dig("message", "creator", "id")
    assert_equal @room.id, row.dig("room", "id")
  end

  test "polling omits rows for revoked rooms" do
    dm = rooms(:bender_and_kevin)
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    dm_grant = AgentGrant.create!(agent: @agent, room: dm, granted_by: users(:david), capability: "read_messages")

    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-revoked-room"
    )
    dm.messages.create!(creator: users(:kevin), body: "DM hello", client_message_id: "poll-revoked-dm")

    get agents_events_url, headers: bearer_headers
    assert_equal 2, response.parsed_body.size

    dm_grant.revoke!

    get agents_events_url, headers: bearer_headers
    assert_response :success
    assert_equal [ "mention" ], response.parsed_body.map { |row| row["event_type"] }
  end

  test "polling is forbidden when the last read grant is revoked" do
    grant = AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-revoked-all"
    )

    get agents_events_url, headers: bearer_headers
    assert_equal 1, response.parsed_body.size

    grant.revoke!

    get agents_events_url, headers: bearer_headers
    assert_response :forbidden
  end

  test "polling omits rows after membership removal" do
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-membership"
    )

    get agents_events_url, headers: bearer_headers
    assert_equal 1, response.parsed_body.size

    memberships(:bender_watercooler).destroy!

    get agents_events_url, headers: bearer_headers
    assert_response :success
    assert_empty response.parsed_body
  end

  test "polling omits rows for deleted messages" do
    message = @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-deleted"
    )
    event_id = @agent.agent_events.deliverable.last.id
    message.destroy!

    get agents_events_url, headers: bearer_headers

    assert_response :success
    assert_not_includes response.parsed_body.map { |row| row["id"] }, event_id
  end

  test "polling respects since and limit with a max of 100" do
    3.times do |i|
      @room.messages.create!(
        creator: users(:david), body: "Ping #{i} #{mention_attachment_for(:bender)}",
        client_message_id: "poll-since-#{i}"
      )
    end
    ids = @agent.agent_events.deliverable.ordered.pluck(:id)

    get agents_events_url(since: ids.first), headers: bearer_headers
    assert_equal ids[1..], response.parsed_body.map { |row| row["id"] }

    get agents_events_url(limit: 2), headers: bearer_headers
    assert_equal 2, response.parsed_body.size

    get agents_events_url(limit: 500), headers: bearer_headers
    assert_response :success
    assert_operator response.parsed_body.size, :<=, 100
  end

  test "polling excludes ledger-only suppression and posted rows" do
    @room.messages.create!(creator: @bot, body: "Agent post", client_message_id: "poll-posted")
    @agent.agent_events.create!(
      event_type: "delivery_suppressed_rate_limit", room: @room,
      outcome: "suppressed", detail: "capped"
    )

    get agents_events_url, headers: bearer_headers

    assert_response :success
    assert_empty response.parsed_body
  end

  test "polling requires read_messages anywhere" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")

    get agents_events_url, headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks read_messages capability", response.parsed_body["error"]
  end

  test "polling allows room-scoped read but only returns that room" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    dm = rooms(:bender_and_kevin)

    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-scoped-room"
    )
    dm.messages.create!(creator: users(:kevin), body: "DM hello", client_message_id: "poll-scoped-dm")

    get agents_events_url, headers: bearer_headers

    assert_response :success
    assert_equal [ "mention" ], response.parsed_body.map { |row| row["event_type"] }
  end

  test "polling filters revoked memberships before limiting" do
    2.times do |i|
      @room.messages.create!(
        creator: users(:david), body: "Ping #{i} #{mention_attachment_for(:bender)}",
        client_message_id: "poll-filter-member-#{i}"
      )
    end
    memberships(:bender_watercooler).destroy!
    rooms(:bender_and_kevin).messages.create!(
      creator: users(:kevin), body: "DM hello", client_message_id: "poll-filter-member-dm"
    )

    get agents_events_url(limit: 1), headers: bearer_headers

    assert_response :success
    assert_equal [ "direct_message" ], response.parsed_body.map { |row| row["event_type"] }
  end

  test "polling filters revoked grants before limiting" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    rooms(:bender_and_kevin).messages.create!(
      creator: users(:kevin), body: "DM hello", client_message_id: "poll-filter-grant-dm"
    )
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-filter-grant-room"
    )

    get agents_events_url(limit: 1), headers: bearer_headers

    assert_response :success
    assert_equal [ "mention" ], response.parsed_body.map { |row| row["event_type"] }
  end

  test "polling is Bearer-only" do
    sign_in :david
    get agents_events_url
    assert_response :forbidden

    delete session_url
    get agents_events_url(bot_key: @bot.bot_key)
    assert_response :forbidden
  end

  test "ack sets acknowledged and is idempotent" do
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-ack"
    )
    event = @agent.agent_events.deliverable.last

    post ack_agents_event_url(event), headers: bearer_headers
    assert_response :success
    assert_equal "acknowledged", response.parsed_body["outcome"]
    assert_equal "acknowledged", event.reload.outcome

    post ack_agents_event_url(event), headers: bearer_headers
    assert_response :success
    assert_equal "acknowledged", event.reload.outcome
  end

  test "ack is 404 for another agent's rows" do
    other_agent = create_agent_in(@room, name: "Ack Bot Other")
    @room.messages.create!(
      creator: users(:david), markdown_source: "Hey @[#{other_agent.user.name}]",
      client_message_id: "poll-ack-other"
    )
    other_event = other_agent.agent_events.deliverable.last

    post ack_agents_event_url(other_event), headers: bearer_headers

    assert_response :not_found
    assert_equal "pending", other_event.reload.outcome
  end

  test "ack requires read_messages in the event room" do
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-ack-revoked"
    )
    event = @agent.agent_events.deliverable.last
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")

    post ack_agents_event_url(event), headers: bearer_headers

    assert_response :forbidden
  end

  test "ack is 404 after membership removal even with a workspace grant" do
    AgentGrant.create!(agent: @agent, room: nil, granted_by: users(:david), capability: "read_messages")
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-ack-workspace"
    )
    event = @agent.agent_events.deliverable.last
    memberships(:bender_watercooler).destroy!

    post ack_agents_event_url(event), headers: bearer_headers

    assert_response :not_found
    assert_equal "pending", event.reload.outcome
  end

  test "ack is 404 for deleted messages" do
    message = @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "poll-ack-deleted"
    )
    event = @agent.agent_events.deliverable.last
    message.destroy!

    post ack_agents_event_url(event), headers: bearer_headers

    assert_response :not_found
  end

  test "agent posts ignore hop hints in the request body" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    agent_b = create_agent_in(@room, name: "Body Hop Bot")
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "body-hop-trigger"
    )
    perform_enqueued_jobs only: Agent::DeliveryJob
    assert_equal "delivered", @agent.agent_events.deliverable.last.outcome

    post room_agent_messages_url(@room),
      params: { message: { markdown_source: "Hey @[#{agent_b.user.name}]", hop: 99 } }.to_json,
      headers: bearer_headers.merge("Content-Type" => "application/json")

    assert_response :created
    assert_equal 1, agent_b.agent_events.deliverable.last.hop
  end

  test "two delivered agents mentioning each other stop at the hop limit with both suppressions" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    agent_b = create_agent_in(@room, name: "Loop Bot B")
    _, secret_b = AgentCredential.create_with_secret!(agent: agent_b, name: "loop", created_by: users(:david))
    webhook_b = Webhook.create!(user: agent_b.user, url: "http://example.com/loop-bot-b")
    WebMock.stub_request(:post, webhook_b.url).to_return(status: 200)

    # Each agent posts only in response to an event actually delivered to
    # it: perform the job, check outcome delivered, then post through the
    # Bearer endpoint. Nothing posts after a suppression.

    human_says "Hey @[#{@bot.name}]", "loop-human-a1"
    assert_delivered @agent, hop: 0

    post_as_agent @secret, "Hey @[#{agent_b.user.name}] one", "loop-a1"
    assert_delivered agent_b, hop: 1

    human_says "Hey @[#{agent_b.user.name}]", "loop-human-b1"
    assert_delivered agent_b, hop: 0

    post_as_agent secret_b, "Hey @[#{@bot.name}] one", "loop-b1"
    assert_delivered @agent, hop: 1

    post_as_agent @secret, "Hey @[#{agent_b.user.name}] two", "loop-a2"
    assert_delivered agent_b, hop: 2

    # B answers its hop-2 delivery at hop 3: suppressed for A, no job.
    assert_no_enqueued_jobs only: Agent::DeliveryJob do
      post_as_agent secret_b, "Hey @[#{@bot.name}] two", "loop-b2"
    end
    assert_suppressed @agent
    # Two deliveries reached A so far (hop 0 and hop 1); the suppressed
    # hop-3 message must not have posted a third.
    assert_requested :post, webhooks(:bender).url, times: 2

    human_says "Hey @[#{@bot.name}] again", "loop-human-a2"
    assert_delivered @agent, hop: 0

    post_as_agent @secret, "Hey @[#{agent_b.user.name}] three", "loop-a3"
    assert_delivered agent_b, hop: 1

    post_as_agent secret_b, "Hey @[#{@bot.name}] three", "loop-b3"
    assert_delivered @agent, hop: 2

    # A answers its hop-2 delivery at hop 3: suppressed for B, no job.
    assert_no_enqueued_jobs only: Agent::DeliveryJob do
      post_as_agent @secret, "Hey @[#{agent_b.user.name}] four", "loop-a4"
    end
    assert_suppressed agent_b

    assert_no_enqueued_jobs only: Agent::DeliveryJob
    # Four deliveries reached each agent across both chains and nothing
    # else was posted: the suppressed messages never hit either webhook.
    assert_requested :post, webhooks(:bender).url, times: 4
    assert_requested :post, webhook_b.url, times: 4
  end

  test "ledger page renders for admins" do
    sign_in :david
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-admin"
    )

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Activity for Bender Bot", response.body
    assert_match "mention", response.body
  end

  test "ledger page renders for the agent owner without admin rights" do
    @agent.update!(owner: users(:kevin))
    sign_in users(:kevin)
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-owner"
    )

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Activity for Bender Bot", response.body
  end

  test "ledger page is forbidden to non-owners" do
    sign_in users(:kevin)

    get agent_events_url(@agent)

    assert_response :forbidden
  end

  test "ledger page is forbidden to Bearer agent tokens" do
    get agent_events_url(@agent), headers: bearer_headers

    assert_response :forbidden
  end

  test "ledger page shows content when the message is currently readable" do
    sign_in :david
    @room.messages.create!(
      creator: users(:david), body: "Readable ledger plans #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-readable"
    )

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Readable ledger plans", response.body
    assert_no_match "Content unavailable", response.body
  end

  test "ledger page redacts content after the agent loses room membership" do
    sign_in :david
    message = @room.messages.create!(
      creator: users(:david), body: "Secret membership plans #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-membership"
    )
    memberships(:bender_watercooler).destroy!

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Content unavailable", response.body
    assert_no_match "Secret membership plans", response.body
    assert_match "message ##{message.id}", response.body
  end

  test "ledger page redacts content after the read grant is revoked" do
    sign_in :david
    grant = AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    @room.messages.create!(
      creator: users(:david), body: "Secret grant plans #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-grant"
    )
    grant.revoke!

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Content unavailable", response.body
    assert_no_match "Secret grant plans", response.body
  end

  test "ledger page redacts content for an owner outside the room" do
    @agent.update!(owner: users(:kevin))
    sign_in users(:kevin)
    @room.messages.create!(
      creator: users(:david), body: "Secret owner plans #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-owner-outside"
    )

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Content unavailable", response.body
    assert_no_match "Secret owner plans", response.body
  end

  test "ledger page shows content to an owner inside the room" do
    @agent.update!(owner: users(:kevin))
    sign_in users(:kevin)
    rooms(:bender_and_kevin).messages.create!(
      creator: users(:kevin), body: "Shared DM plans", client_message_id: "ledger-owner-inside"
    )

    get agent_events_url(@agent)

    assert_response :success
    assert_match "Shared DM plans", response.body
  end

  test "ledger page filters by outcome" do
    sign_in :david
    @room.messages.create!(
      creator: users(:david), body: "Hey #{mention_attachment_for(:bender)}",
      client_message_id: "ledger-filter"
    )
    event = @agent.agent_events.deliverable.last
    event.acknowledged!

    get agent_events_url(@agent, outcome: "acknowledged")
    assert_response :success
    assert_select "menu li", text: /acknowledged/

    get agent_events_url(@agent, outcome: "pending")
    assert_response :success
    assert_select "menu li", text: "No events yet."
  end

  test "a mention in a PR thread carries the pull_request object" do
    thread = discuss_pull_request(number: 12, client_id: "agent-pr-mention")
    thread.post_message!(
      creator: users(:david),
      attributes: { markdown_source: "Hey @[Bender Bot], review this", client_message_id: "agent-pr-mention-1" }
    )

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "mention" }
    assert row, "expected a mention row in #{response.parsed_body.inspect}"
    assert_equal thread.messages.last.id, row.dig("message", "id")
    assert_equal(
      {
        "url" => "https://github.com/rails/rails/pull/12",
        "owner" => "rails",
        "repo" => "rails",
        "number" => 12,
        "title" => "Fix login",
        "state" => "open",
        "head_branch" => "shiny",
        "base_branch" => "main",
        "review_decision" => "approved",
        "checks_state" => "passing"
      },
      row["pull_request"]
    )
  end

  test "mentions elsewhere carry an explicit null pull_request" do
    ordinary_parent = human_says("ordinary starter", "agent-null-parent")
    ordinary = ChannelThread.create!(room: @room, creator: users(:david), name: "Ordinary chat", parent_message: ordinary_parent)
    ordinary.post_message!(
      creator: users(:david),
      attributes: { markdown_source: "Hey @[Bender Bot] in a thread", client_message_id: "agent-null-thread" }
    )
    human_says("Hey @[Bender Bot] in the room", "agent-null-room")

    get agents_events_url, headers: bearer_headers

    assert_response :success
    rows = response.parsed_body.select { |entry| entry["event_type"] == "mention" }
    assert_equal 2, rows.size
    rows.each do |row|
      assert row.key?("pull_request"), "expected an explicit null pull_request in #{row.inspect}"
      assert_nil row["pull_request"]
    end
  end

  private
    def discuss_pull_request(number:, client_id:)
      parent = @room.messages.create!(
        creator: users(:david),
        markdown_source: "review https://github.com/rails/rails/pull/#{number}",
        client_message_id: client_id
      )
      pull_request = parent.github_pull_requests.first
      pull_request.update!(
        title: "Fix login", state: "open", base_branch: "main", head_branch: "shiny",
        review_decision: "approved", check_status: "passing",
        html_url: "https://github.com/rails/rails/pull/#{number}"
      )
      thread = ChannelThread.create!(room: @room, creator: users(:david), name: "PR chat", parent_message: parent)
      ThreadMembership.join!(thread, users(:david))
      Github::PullRequestThread.create!(pull_request: pull_request, room: @room, channel_thread: thread)
      thread
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}" }
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      room.memberships.grant_to(bot)
      agent
    end

    def human_says(markdown, client_message_id)
      @room.messages.create!(
        creator: users(:david), markdown_source: markdown, client_message_id: client_message_id
      )
    end

    def post_as_agent(secret, markdown, client_message_id)
      post room_agent_messages_url(@room),
        params: { message: { markdown_source: markdown, client_message_id: client_message_id } }.to_json,
        headers: { "Authorization" => "Bearer #{secret}", "Content-Type" => "application/json" }
      assert_response :created
    end

    def assert_delivered(agent, hop:)
      perform_enqueued_jobs only: Agent::DeliveryJob

      event = agent.agent_events.deliverable.last
      assert_equal "delivered", event.outcome
      assert_equal hop, event.hop
    end

    def assert_suppressed(agent)
      assert agent.agent_events.where(event_type: "delivery_suppressed_hop_limit").exists?,
        "expected a hop-limit suppression for agent #{agent.id}"
    end
end
