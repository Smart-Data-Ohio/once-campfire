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

  test "ledger page is forbidden to Bearer [REDACTED]" do
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

  private
    def bearer_headers
      { "Authorization" => "Bearer #{@secret}" }
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      room.memberships.grant_to(bot)
      agent
    end
end
