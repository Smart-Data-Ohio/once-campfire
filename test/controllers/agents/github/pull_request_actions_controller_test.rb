require "test_helper"

class Agents::Github::PullRequestActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    discuss_pull_request(number: 12)
  end

  test "a bad Bearer [REDACTED] is 401" do
    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: { "Authorization" => "Bearer wrong-secret", "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a suspended agent is 401" do
    @agent.update!(suspended_at: Time.current)

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :unauthorized
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a room the agent is not a member of is 404" do
    grant_external!(room: nil)
    link_github!

    post room_agent_github_pull_request_actions_url(rooms(:designers)),
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :not_found
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "an unknown room is 404" do
    grant_external!(room: nil)
    link_github!

    post room_agent_github_pull_request_actions_url(rooms(:designers).id + 100_000),
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :not_found
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a pull request the room does not discuss is 404" do
    grant_external!
    link_github!
    undiscussed = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 13)

    post action_url,
      params: { pull_request_id: undiscussed.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :not_found
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a mapping in another room is 404" do
    grant_external!
    link_github!

    other_room = rooms(:designers)
    message = other_room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/14",
      client_message_id: "agent-action-other-room"
    )
    other_pr = message.github_pull_requests.first
    thread = ChannelThread.create!(room: other_room, creator: users(:david), parent_message: message)
    Github::PullRequestThread.create!(pull_request: other_pr, room: other_room, channel_thread: thread)

    post action_url,
      params: { pull_request_id: other_pr.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :not_found
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a missing pull_request_id is 404" do
    grant_external!
    link_github!

    post action_url,
      params: { kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :not_found
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a missing external_action grant is 403 with the approvals error shape" do
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "post_messages")
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks external_action capability", response.parsed_body["error"]
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "an external_action grant in another room is 403" do
    grant_external!(room: rooms(:designers))
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :forbidden
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "an agent without a linked GitHub account is 422" do
    grant_external!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_equal "Agent has no usable GitHub account", response.parsed_body["error"]
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "an agent with a disconnected account is 422" do
    grant_external!
    link_github!.mark_disconnected!("GitHub rejected the linked token (401)")

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_equal "Agent has no usable GitHub account", response.parsed_body["error"]
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a comment without a body is 422 with field errors" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "  " }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_equal({ "body" => [ "is required for a comment" ] }, response.parsed_body["errors"])
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "request_changes without a body is 422 with field errors" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "request_changes" }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_equal({ "body" => [ "is required when requesting changes" ] }, response.parsed_body["errors"])
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "request_review without valid logins is 422 with field errors" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "request_review", reviewers: "alice, bob!!" }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_equal({ "reviewers" => [ "Enter GitHub usernames separated by commas." ] }, response.parsed_body["errors"])
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "an unknown kind is 422 with field errors" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "merge", body: "hi" }.to_json,
      headers: bearer_headers

    assert_response :unprocessable_entity
    assert_equal(
      { "kind" => [ "must be one of: comment, approve, request_changes, request_review" ] },
      response.parsed_body["errors"]
    )
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a legacy bot key is rejected" do
    delete session_url

    post room_agent_github_pull_request_actions_url(@room, bot_key: @bot.bot_key),
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :forbidden
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a human session is rejected" do
    sign_in :david

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "hi" }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :forbidden
    assert_equal "Forbidden: Bearer [REDACTED] token required", response.parsed_body["error"]
    assert_not_requested :any, %r{api\.github\.com}
  end

  test "a comment request creates one approval and returns 202 without calling GitHub" do
    grant_external!
    link_github!

    assert_difference -> { AgentApproval.count }, 1 do
      post action_url,
        params: { pull_request_id: @pull_request.id, kind: "comment", body: "Nice work", external_id: "gh-1" }.to_json,
        headers: bearer_headers
    end

    assert_response :accepted
    payload = response.parsed_body
    assert payload["id"].present?
    assert_equal "pending", payload["status"]
    assert payload["expires_at"].present?
    assert_not_requested :any, %r{api\.github\.com}

    approval = AgentApproval.find(payload["id"])
    assert_equal @agent, approval.agent
    assert_equal @room, approval.room
    assert_equal "github.comment", approval.action
    assert_equal "Comment on rails/rails#12: Nice work", approval.summary
    assert_equal(
      { "pull_request_id" => @pull_request.id, "kind" => "comment", "body" => "Nice work", "reviewers" => nil },
      JSON.parse(approval.payload)
    )
    assert_equal "gh-1", approval.external_id
    assert ActivityItem.exists?(user: users(:david), source: approval)
  end

  test "approve, request_changes, and request_review build their own payloads" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "approve" }.to_json,
      headers: bearer_headers
    assert_response :accepted
    approval = AgentApproval.find(response.parsed_body["id"])
    assert_equal "github.approve", approval.action
    assert_equal "Approve rails/rails#12", approval.summary
    assert_equal(
      { "pull_request_id" => @pull_request.id, "kind" => "approve", "body" => nil, "reviewers" => nil },
      JSON.parse(approval.payload)
    )

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "request_changes", body: "Fix the typo" }.to_json,
      headers: bearer_headers
    assert_response :accepted
    approval = AgentApproval.find(response.parsed_body["id"])
    assert_equal "github.request_changes", approval.action
    assert_equal "Request changes on rails/rails#12", approval.summary
    assert_equal "Fix the typo", JSON.parse(approval.payload)["body"]

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "request_review", reviewers: " @Alice, alice  @BOB " }.to_json,
      headers: bearer_headers
    assert_response :accepted
    approval = AgentApproval.find(response.parsed_body["id"])
    assert_equal "github.request_review", approval.action
    assert_equal "Request review on rails/rails#12 from @alice, @bob", approval.summary
    assert_equal %w[ alice bob ], JSON.parse(approval.payload)["reviewers"]

    assert_not_requested :any, %r{api\.github\.com}
  end

  test "reviewers also accept an array" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "request_review", reviewers: [ "alice", "@bob" ] }.to_json,
      headers: bearer_headers

    assert_response :accepted
    assert_equal %w[ alice bob ], JSON.parse(AgentApproval.find(response.parsed_body["id"]).payload)["reviewers"]
  end

  test "a repeated external_id returns the existing row with 200" do
    grant_external!
    link_github!

    post action_url,
      params: { pull_request_id: @pull_request.id, kind: "comment", body: "First", external_id: "gh-dup" }.to_json,
      headers: bearer_headers
    assert_response :accepted
    first_id = response.parsed_body["id"]

    assert_no_difference -> { AgentApproval.count } do
      post action_url,
        params: { pull_request_id: @pull_request.id, kind: "comment", body: "Second", external_id: "gh-dup" }.to_json,
        headers: bearer_headers
    end

    assert_response :success
    assert_equal first_id, response.parsed_body["id"]
    assert_equal "Comment on rails/rails#12: First", AgentApproval.find(first_id).summary
    assert_not_requested :any, %r{api\.github\.com}
  end

  private
    def action_url
      room_agent_github_pull_request_actions_url(@room)
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end

    def grant_external!(room: @room)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: "external_action")
    end

    def link_github!(token: "agent-token-abc")
      GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: token)
    end

    def discuss_pull_request(number:)
      message = @room.messages.create!(
        creator: users(:david),
        markdown_source: "review https://github.com/rails/rails/pull/#{number}",
        client_message_id: "agent-action-pr-#{number}"
      )
      @pull_request = message.github_pull_requests.first
      thread = ChannelThread.create!(room: @room, creator: users(:david), parent_message: message)
      ThreadMembership.join!(thread, users(:david))
      Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)
    end
end
