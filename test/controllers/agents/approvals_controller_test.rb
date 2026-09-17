require "test_helper"

class Agents::ApprovalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "create allows with a room grant and returns id, status, and expires_at" do
    grant!(capability: "external_action", room: @room)

    assert_difference -> { AgentApproval.count }, 1 do
      post agents_approvals_url,
        params: { approval: { action: "deploy", summary: "Ship it", room_id: @room.id } }.to_json,
        headers: bearer_headers
    end

    assert_response :created
    payload = response.parsed_body
    assert payload["id"].present?
    assert_equal "pending", payload["status"]
    assert payload["expires_at"].present?

    approval = AgentApproval.find(payload["id"])
    assert_equal @agent, approval.agent
    assert_equal @room, approval.room
    assert_equal "deploy", approval.action
  end

  test "create allows workspace-wide when no room is given" do
    grant!(capability: "external_action")

    post agents_approvals_url,
      params: { approval: { action: "deploy", summary: "Ship it" } }.to_json,
      headers: bearer_headers

    assert_response :created
    assert_nil AgentApproval.last.room_id
  end

  test "create accepts top-level fields with the raw action" do
    grant!(capability: "external_action")

    post agents_approvals_url,
      params: { action: "deploy", summary: "Top level", expires_in: 3600 }.to_json,
      headers: bearer_headers

    assert_response :created
    assert_equal "deploy", AgentApproval.last.action
    assert_in_delta 1.hour.from_now.to_i, AgentApproval.last.expires_at.to_i, 120
  end

  test "create is 403 without external_action" do
    grant!(capability: "post_messages", room: @room)

    post agents_approvals_url,
      params: { approval: { action: "deploy", summary: "Ship it", room_id: @room.id } }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks external_action capability", response.parsed_body["error"]
  end

  test "create is 403 when the grant covers another room" do
    grant!(capability: "external_action", room: rooms(:designers))

    post agents_approvals_url,
      params: { approval: { action: "deploy", summary: "Ship it", room_id: @room.id } }.to_json,
      headers: bearer_headers

    assert_response :forbidden
  end

  test "create without a room requires a workspace-wide grant" do
    grant!(capability: "external_action", room: @room)

    post agents_approvals_url,
      params: { approval: { action: "deploy", summary: "Ship it" } }.to_json,
      headers: bearer_headers

    assert_response :forbidden
  end

  test "create is 404 when the agent is not a member of the room" do
    grant!(capability: "external_action")
    memberships(:bender_watercooler).destroy!

    post agents_approvals_url,
      params: { approval: { action: "deploy", summary: "Ship it", room_id: @room.id } }.to_json,
      headers: bearer_headers

    assert_response :not_found
  end

  test "create is Bearer-only" do
    sign_in :david
    post agents_approvals_url, params: { approval: { action: "deploy", summary: "x" } }
    assert_response :forbidden
  end

  test "create replays the existing row for a repeated external_id" do
    grant!(capability: "external_action", room: @room)

    post agents_approvals_url,
      params: { approval: { action: "deploy", summary: "First", room_id: @room.id, external_id: "idempotency-1" } }.to_json,
      headers: bearer_headers
    assert_response :created
    first_id = response.parsed_body["id"]

    assert_no_difference -> { AgentApproval.count } do
      post agents_approvals_url,
        params: { approval: { action: "deploy", summary: "Second", room_id: @room.id, external_id: "idempotency-1" } }.to_json,
        headers: bearer_headers
    end

    assert_response :success
    assert_equal first_id, response.parsed_body["id"]
    assert_equal "First", AgentApproval.find(first_id).summary
  end

  test "create refuses github.* actions, which only the pull request actions endpoint may create" do
    grant!(capability: "external_action", room: @room)

    assert_no_difference -> { AgentApproval.count } do
      post agents_approvals_url,
        params: { approval: { action: "github.comment", summary: "Comment on rails/rails#1: hi", room_id: @room.id,
          payload: { pull_request_id: 1, kind: "approve" }.to_json } }.to_json,
        headers: bearer_headers
    end

    assert_response :unprocessable_entity
    assert_match "pull_request_actions", response.parsed_body["error"]
  end

  test "create validates the approval fields" do
    grant!(capability: "external_action", room: @room)

    post agents_approvals_url,
      params: { approval: { action: "Bad Action!", summary: "x", room_id: @room.id } }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_match "Action", response.parsed_body["error"]
  end

  test "show returns the row with effective status and decision" do
    grant!(capability: "external_action", room: @room)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.decide!(decision: "approved", by: users(:david), note: "go")

    get "/agents/approvals/#{approval.id}", headers: bearer_headers

    assert_response :success
    payload = response.parsed_body
    assert_equal approval.id, payload["id"]
    assert_equal "deploy", payload["action"]
    assert_equal "approved", payload["status"]
    assert_equal "David", payload["decided_by"]
    assert_equal "go", payload["note"]
  end

  test "show is 404 for another agent's row" do
    grant!(capability: "external_action", room: @room)
    other_agent = create_agent_in(@room, name: "Show Other Bot")
    other = AgentApproval.create!(agent: other_agent, room: @room, action: "deploy", summary: "other")

    get "/agents/approvals/#{other.id}", headers: bearer_headers

    assert_response :not_found
  end

  test "show is 403 without external_action in the approval room" do
    grant!(capability: "external_action", room: rooms(:designers))
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    get "/agents/approvals/#{approval.id}", headers: bearer_headers

    assert_response :forbidden
  end

  test "show reads expired for an overdue pending row" do
    grant!(capability: "external_action", room: @room)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.update_columns(expires_at: 1.minute.ago)

    get "/agents/approvals/#{approval.id}", headers: bearer_headers

    assert_response :success
    assert_equal "expired", response.parsed_body["status"]
    assert_equal "expired", approval.reload.status
  end

  test "list returns the agent's own rows newest first with a status filter" do
    grant!(capability: "external_action", room: @room)
    other_agent = create_agent_in(@room, name: "List Other Bot")
    AgentApproval.create!(agent: other_agent, room: @room, action: "deploy", summary: "other")
    first = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "first")
    second = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "second")
    first.decide!(decision: "denied", by: users(:david))

    get agents_approvals_url, headers: bearer_headers
    assert_response :success
    assert_equal [ second.id, first.id ], response.parsed_body.map { |row| row["id"] }

    get agents_approvals_url(status: "pending"), headers: bearer_headers
    assert_response :success
    assert_equal [ second.id ], response.parsed_body.map { |row| row["id"] }

    get agents_approvals_url(status: "denied"), headers: bearer_headers
    assert_response :success
    assert_equal [ first.id ], response.parsed_body.map { |row| row["id"] }
  end

  test "list excludes lazily-expired rows from the pending filter" do
    grant!(capability: "external_action", room: @room)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.update_columns(expires_at: 1.minute.ago)

    get agents_approvals_url(status: "pending"), headers: bearer_headers
    assert_response :success
    assert_empty response.parsed_body

    get agents_approvals_url(status: "expired"), headers: bearer_headers
    assert_response :success
    assert_equal [ approval.id ], response.parsed_body.map { |row| row["id"] }
  end

  test "list is 403 without any external_action grant" do
    get agents_approvals_url, headers: bearer_headers
    assert_response :forbidden
  end

  test "cancel marks a pending request cancelled" do
    grant!(capability: "external_action", room: @room)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    delete "/agents/approvals/#{approval.id}", headers: bearer_headers

    assert_response :success
    assert_equal "cancelled", response.parsed_body["status"]
    assert_equal "cancelled", approval.reload.status
  end

  test "cancel is 404 for another agent's row" do
    grant!(capability: "external_action", room: @room)
    other_agent = create_agent_in(@room, name: "Cancel Other Bot")
    other = AgentApproval.create!(agent: other_agent, room: @room, action: "deploy", summary: "other")

    delete "/agents/approvals/#{other.id}", headers: bearer_headers

    assert_response :not_found
    assert_equal "pending", other.reload.status
  end

  test "cancel is 422 once decided or expired" do
    grant!(capability: "external_action", room: @room)
    decided = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "decided")
    decided.decide!(decision: "approved", by: users(:david))

    delete "/agents/approvals/#{decided.id}", headers: bearer_headers
    assert_response :unprocessable_entity

    overdue = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "overdue")
    overdue.update_columns(expires_at: 1.minute.ago)

    delete "/agents/approvals/#{overdue.id}", headers: bearer_headers
    assert_response :unprocessable_entity
    assert_equal "expired", overdue.reload.status
  end

  test "cancel appends no ledger event" do
    grant!(capability: "external_action", room: @room)
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    assert_no_difference -> { @agent.agent_events.where(event_type: "approval_decided").count } do
      delete "/agents/approvals/#{approval.id}", headers: bearer_headers
    end
    assert_response :success
  end

  test "html list renders for deciders and 404s for others" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    sign_in :david
    get agent_approvals_url(@agent)
    assert_response :success
    assert_match "Approvals for Bender Bot", response.body
    assert_match "Ship it", response.body

    sign_in users(:kevin)
    get agent_approvals_url(@agent)
    assert_response :not_found

    get agent_approvals_url(@agent), headers: bearer_headers
    assert_response :not_found
  end

  test "html list filters by status" do
    sign_in :david
    pending = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "pending one")
    decided = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "decided one")
    decided.decide!(decision: "approved", by: users(:david))

    get agent_approvals_url(@agent, status: "approved")
    assert_response :success
    assert_match "decided one", response.body
    assert_no_match "pending one", response.body
    assert pending.reload.pending_effective?
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end

    def create_agent_in(room, name:)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      room.memberships.grant_to(bot)
      agent
    end
end
