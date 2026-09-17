require "test_helper"

class Agents::WorkDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")
  end

  test "assignment appears in event polling with the work payload" do
    thread = assign_owned_thread!(name: "Polled work")

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "work_assigned" }
    assert row, "expected a work_assigned row in #{response.parsed_body.inspect}"
    assert_equal "delivered", row["outcome"]
    assert_nil row["message"]
    assert_equal @room.id, row.dig("room", "id")
    assert_equal "David", row.dig("actor", "name")
    assert_equal thread.id, row.dig("work", "thread_id")
    assert_equal @room.id, row.dig("work", "room_id")
    assert_equal "Polled work", row.dig("work", "title")
    assert_equal "planned", row.dig("work", "status")
    assert_equal room_path(@room, thread: thread.id), row.dig("work", "url")
    assert_equal "David", row.dig("work", "assigned_by")
  end

  test "assignment work payload includes links" do
    thread = assign_owned_thread!(name: "Linked assignment")
    thread.work_thread_links.create!(kind: :event, event: events(:watercooler_sync), created_by: users(:david))
    drive_url = "https://drive.google.com/file/d/1AbcDefGhIjKlMnOpQrSt/view"
    thread.work_thread_links.create!(kind: :drive_file, url: drive_url, created_by: users(:david))

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "work_assigned" }
    links = row.dig("work", "links")
    assert_equal %w[ event drive_file ], links.map { |entry| entry["kind"] }
    assert_equal room_event_path(@room, events(:watercooler_sync)), links.first["url"]
    assert_equal drive_url, links.second["url"]
    assert_nil links.second["title"]
  end

  test "unassignment appears in event polling" do
    thread = assign_owned_thread!(name: "Unassigned work")
    thread.update_work!(actor: users(:david), work_owner_id: nil)

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "work_unassigned" }
    assert row, "expected a work_unassigned row in #{response.parsed_body.inspect}"
    assert_equal thread.id, row.dig("work", "thread_id")
    assert_equal "Unassigned work", row.dig("work", "title")
  end

  test "ack works on work rows" do
    assign_owned_thread!(name: "Acked work")
    event = @agent.agent_events.where(event_type: "work_assigned").last

    post ack_agents_event_url(event), headers: bearer_headers

    assert_response :success
    assert_equal "acknowledged", response.parsed_body["outcome"]
    assert_equal "acknowledged", event.reload.outcome
  end

  test "assignment posts the webhook with agent and work keys" do
    stub = WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    thread = assign_owned_thread!(name: "Hooked work")

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "agent" => hash_including("id" => @agent.id, "name" => "Bender Bot"),
      "event_type" => "work_assigned",
      "work" => hash_including(
        "thread_id" => thread.id,
        "room_id" => @room.id,
        "title" => "Hooked work",
        "status" => "planned",
        "assigned_by" => "David"
      )
    ), times: 1
    assert_requested stub
  end

  test "assignment posts no webhook without read_messages" do
    AgentGrant.where(agent: @agent, capability: "read_messages").update_all(revoked_at: Time.current)
    stub = WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_difference -> { @agent.agent_events.where(event_type: "work_assigned").count }, 1 do
      assign_owned_thread!(name: "Unread work")
    end

    assert_not_requested :post, webhooks(:bender).url
    assert_requested stub, times: 0
  end

  test "polling omits work rows for rooms the agent lost read_messages in" do
    dm = rooms(:bender_and_kevin)
    AgentGrant.create!(agent: @agent, room: dm, granted_by: users(:david), capability: "read_messages")
    assign_owned_thread!(name: "Revoked work")

    get agents_events_url, headers: bearer_headers
    assert_equal 1, response.parsed_body.size

    AgentGrant.where(agent: @agent, room: @room, capability: "read_messages").sole.revoke!

    get agents_events_url, headers: bearer_headers
    assert_response :success
    assert_empty response.parsed_body
  end

  test "polling omits work rows after membership removal" do
    AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "read_messages")
    assign_owned_thread!(name: "Left work")

    get agents_events_url, headers: bearer_headers
    assert_equal 1, response.parsed_body.size

    memberships(:bender_watercooler).destroy!

    get agents_events_url, headers: bearer_headers
    assert_response :success
    assert_empty response.parsed_body
  end

  test "work events do not count toward the message rate limit" do
    20.times do |i|
      @room.messages.create!(
        creator: users(:david), body: "Ping #{i} #{mention_attachment_for(:bender)}",
        client_message_id: "work-rate-#{i}"
      )
    end
    assert_equal 20, @agent.agent_events.message_deliverable.where(room: @room).count

    thread = assign_owned_thread!(name: "Rate work")
    thread.update_work!(actor: users(:david), work_owner_id: nil)
    assert_equal 2, @agent.agent_events.where(event_type: %w[ work_assigned work_unassigned ]).count

    @room.messages.create!(
      creator: users(:david), body: "One more #{mention_attachment_for(:bender)}",
      client_message_id: "work-rate-overflow"
    )

    assert @agent.agent_events.where(event_type: "delivery_suppressed_rate_limit").exists?,
      "the 21st message should still rate-limit after work events"
  end

  private
    def bearer_headers
      { "Authorization" => "Bearer #{@secret}" }
    end

    def assign_owned_thread!(name:)
      thread = ChannelThread.create!(room: @room, creator: users(:david), name: name)
      ThreadMembership.join!(thread, users(:david))
      thread.update_work!(actor: users(:david), work_status: "planned", work_owner_id: @bot.id)
      thread
    end
end
