require "test_helper"

class Agents::ApprovalDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "external_action")
  end

  test "decision appends an approval_decided ledger row" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    assert_difference -> { @agent.agent_events.where(event_type: "approval_decided").count }, 1 do
      approval.decide!(decision: "approved", by: users(:david), note: "go")
    end

    event = @agent.agent_events.where(event_type: "approval_decided").last
    assert_equal "delivered", event.outcome
    assert_nil event.message_id
    assert_equal approval.id, event.metadata["approval_id"]
    assert_equal "approved", event.metadata["status"]
    assert_equal "David", event.metadata["decided_by"]
    assert_equal "go", event.metadata["note"]
  end

  test "decision appears in event polling with the approval payload" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.decide!(decision: "denied", by: users(:david), note: "not now")

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "approval_decided" }
    assert row, "expected an approval_decided row in #{response.parsed_body.inspect}"
    assert_equal "delivered", row["outcome"]
    assert_nil row["message"]
    assert_equal approval.id, row.dig("approval", "approval_id")
    assert_equal "denied", row.dig("approval", "status")
    assert_equal "David", row.dig("approval", "decided_by")
    assert_equal "not now", row.dig("approval", "note")
  end

  test "ack works on approval rows" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.decide!(decision: "approved", by: users(:david))
    event = @agent.agent_events.where(event_type: "approval_decided").last

    post ack_agents_event_url(event), headers: bearer_headers

    assert_response :success
    assert_equal "acknowledged", response.parsed_body["outcome"]
    assert_equal "acknowledged", event.reload.outcome
  end

  test "decision posts the webhook with agent and approval keys" do
    stub = WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    approval.decide!(decision: "approved", by: users(:david), note: "go")

    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "agent" => hash_including("id" => @agent.id, "name" => "Bender Bot"),
      "approval" => hash_including(
        "approval_id" => approval.id,
        "status" => "approved",
        "decided_by" => "David",
        "note" => "go"
      )
    ), times: 1
    assert_requested stub
  end

  test "approval decisions do not count toward the message rate limit" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    20.times do |i|
      @room.messages.create!(
        creator: users(:david), body: "Ping #{i} #{mention_attachment_for(:bender)}",
        client_message_id: "approval-rate-#{i}"
      )
    end
    assert_equal 20, @agent.agent_events.message_deliverable.where(room: @room).count

    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.decide!(decision: "approved", by: users(:david))

    @room.messages.create!(
      creator: users(:david), body: "One more #{mention_attachment_for(:bender)}",
      client_message_id: "approval-rate-overflow"
    )

    assert @agent.agent_events.where(event_type: "delivery_suppressed_rate_limit").exists?,
      "the 21st message should still rate-limit after an approval decision"
  end

  private
    def bearer_headers
      { "Authorization" => "Bearer #{@secret}" }
    end
end
