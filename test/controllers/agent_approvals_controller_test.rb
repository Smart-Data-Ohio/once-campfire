require "test_helper"

class AgentApprovalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
  end

  test "owner can approve" do
    @agent.update!(owner: users(:kevin))
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    sign_in users(:kevin)

    patch agent_approval_url(approval, decision: "approved"), as: :json

    assert_response :success
    assert_equal "approved", response.parsed_body["status"]
    assert_equal "approved", approval.reload.status
    assert_equal users(:kevin), approval.decided_by
  end

  test "admin can deny with a note" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    sign_in :david

    patch agent_approval_url(approval, decision: "denied", decision_note: "not now"), as: :json

    assert_response :success
    assert_equal "denied", approval.reload.status
    assert_equal "not now", approval.decision_note
  end

  test "plain member gets 404" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    sign_in users(:kevin)

    patch agent_approval_url(approval, decision: "approved"), as: :json

    assert_response :not_found
    assert_equal "pending", approval.reload.status
  end

  test "switching approvals off keeps the approvals page available" do
    @agent.update!(owner: users(:kevin))
    users(:kevin).update!(inbox_preferences: { "agent_approvals" => false })
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    sign_in users(:kevin)

    assert_not ActivityItem.exists?(user: users(:kevin), source: approval)

    get agent_approvals_path(@agent)

    assert_response :success
    assert_includes response.body, "Ship it"
  end

  test "agent Bearer [REDACTED] 404" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    patch agent_approval_url(approval, decision: "approved"),
      headers: { "Authorization" => "Bearer #{@secret}" }, as: :json

    assert_response :not_found
    assert_equal "pending", approval.reload.status
  end

  test "deciding an expired row is 422" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    approval.update_columns(expires_at: 1.minute.ago)
    sign_in :david

    patch agent_approval_url(approval, decision: "approved"), as: :json

    assert_response :unprocessable_entity
    assert_match "expired", response.parsed_body["error"]
    assert_equal "expired", approval.reload.status
  end

  test "deciding twice is 422" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    sign_in :david

    patch agent_approval_url(approval, decision: "approved"), as: :json
    assert_response :success

    patch agent_approval_url(approval, decision: "denied"), as: :json
    assert_response :unprocessable_entity
  end

  test "deciding marks every decider inbox item handled" do
    @agent.update!(owner: users(:kevin))
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    items = ActivityItem.where(source: approval).to_a
    assert_equal 3, items.size
    assert items.all?(&:unread?)

    sign_in :david
    patch agent_approval_url(approval, decision: "approved"), as: :json
    assert_response :success

    assert items.all? { |item| item.reload.handled? }
  end

  test "handling an inbox item leaves the request pending" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    item = ActivityItem.find_by!(user: users(:david), source: approval)
    sign_in :david

    patch handled_activity_item_url(item), params: { state: "handled" }, as: :json
    assert_response :success

    assert_predicate item.reload, :handled?
    assert_equal "pending", approval.reload.status
    assert_equal "pending", approval.effective_status
  end

  test "marking an inbox item read leaves the request pending" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    item = ActivityItem.find_by!(user: users(:david), source: approval)
    sign_in :david

    patch read_activity_item_url(item), params: { state: "read" }, as: :json
    assert_response :success

    assert_predicate item.reload, :read?
    assert_equal "pending", approval.reload.status
  end

  test "html decision redirects back with a notice" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    sign_in :david

    patch agent_approval_url(approval, decision: "approved")

    assert_response :see_other
    assert_equal "approved", approval.reload.status
  end
end
