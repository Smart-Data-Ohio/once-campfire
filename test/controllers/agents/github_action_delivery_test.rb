require "test_helper"

class Agents::GithubActionDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "read_messages")
    AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "external_action")
    GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "agent-token-abc")
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "github-action-delivery-pr-12"
    )
    @pull_request = message.github_pull_requests.first
    thread = ChannelThread.create!(room: @room, creator: users(:david), parent_message: message)
    ThreadMembership.join!(thread, users(:david))
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)
  end

  test "an approved action records a completed ledger row with the GitHub url" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")

    assert_difference -> { @agent.agent_events.where(event_type: "github_action_completed").count }, 1 do
      approval.decide!(decision: "approved", by: users(:david))
      perform_enqueued_jobs only: Github::PerformAgentActionJob
    end

    event = @agent.agent_events.where(event_type: "github_action_completed").last
    assert_equal "delivered", event.outcome
    assert_equal @room, event.room
    assert_nil event.message_id
    assert_equal(
      {
        "approval_id" => approval.id,
        "action" => "github.comment",
        "status" => "completed",
        "url" => "https://github.com/rails/rails/pull/12#issuecomment-1"
      },
      event.metadata
    )
  end

  test "a failed action records the reason without a url" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    perform_enqueued_jobs only: Github::PerformAgentActionJob

    event = @agent.agent_events.where(event_type: "github_action_completed").last
    assert_equal(
      {
        "approval_id" => approval.id,
        "action" => "github.comment",
        "status" => "failed",
        "message" => "GitHub refused: Resource not accessible by personal access token"
      },
      event.metadata
    )
  end

  test "completion appears in event polling with the github_action payload" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    perform_enqueued_jobs only: Github::PerformAgentActionJob

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "github_action_completed" }
    assert row, "expected a github_action_completed row in #{response.parsed_body.inspect}"
    assert_equal "delivered", row["outcome"]
    assert_nil row["message"]
    assert_equal(
      {
        "approval_id" => approval.id,
        "action" => "github.comment",
        "status" => "completed",
        "url" => "https://github.com/rails/rails/pull/12#issuecomment-1"
      },
      row["github_action"]
    )
    assert_equal @room.id, row.dig("room", "id")
  end

  test "failed completions poll with the message and no url" do
    # Losing the room revokes its grants, so a surviving grant elsewhere
    # keeps polling allowed while the completion stays readable.
    AgentGrant.create!(agent: @agent, room: rooms(:bender_and_kevin), granted_by: users(:david), capability: "read_messages")
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    memberships(:bender_watercooler).destroy!
    perform_enqueued_jobs only: Github::PerformAgentActionJob

    get agents_events_url, headers: bearer_headers

    assert_response :success
    row = response.parsed_body.find { |entry| entry["event_type"] == "github_action_completed" }
    assert row, "expected a github_action_completed row in #{response.parsed_body.inspect}"
    assert_equal "failed", row.dig("github_action", "status")
    assert_equal "Agent is no longer a member of the room", row.dig("github_action", "message")
    assert_not row["github_action"].key?("url")
  end

  test "ack works on completion rows" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    perform_enqueued_jobs only: Github::PerformAgentActionJob
    event = @agent.agent_events.where(event_type: "github_action_completed").last

    post ack_agents_event_url(event), headers: bearer_headers

    assert_response :success
    assert_equal "acknowledged", response.parsed_body["outcome"]
    assert_equal "acknowledged", event.reload.outcome
  end

  test "completion posts the webhook with agent and github_action keys" do
    stub = WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    perform_enqueued_jobs only: Github::PerformAgentActionJob

    assert_requested stub, times: 2 # the approval decision plus the completion
    completion = @agent.agent_events.where(event_type: "github_action_completed").last
    assert_requested :post, webhooks(:bender).url, body: hash_including(
      "agent" => hash_including("id" => @agent.id, "name" => "Bender Bot", "delivery_id" => completion.id),
      "github_action" => hash_including(
        "approval_id" => approval.id,
        "action" => "github.comment",
        "status" => "completed",
        "url" => "https://github.com/rails/rails/pull/12#issuecomment-1"
      )
    ), times: 1
  end

  test "completion rows are readable by their own agent only" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    perform_enqueued_jobs only: Github::PerformAgentActionJob
    event = @agent.agent_events.where(event_type: "github_action_completed").last

    assert_includes @agent.agent_events.readable_by(@agent).to_a, event

    other_agent, other_secret = create_agent_with_secret("Github Completion Other Bot")
    AgentGrant.create!(agent: other_agent, room: @room, granted_by: users(:david), capability: "read_messages")

    get agents_events_url, headers: { "Authorization" => "Bearer #{other_secret}" }
    assert_response :success
    assert_empty response.parsed_body.select { |entry| entry["event_type"] == "github_action_completed" }

    post ack_agents_event_url(event), headers: { "Authorization" => "Bearer #{other_secret}" }
    assert_response :not_found
    assert_equal "delivered", event.reload.outcome
  end

  test "the ledger page lists the completion with its status" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    perform_enqueued_jobs only: Github::PerformAgentActionJob

    sign_in :david
    get agent_events_url(@agent)

    assert_response :success
    assert_match "github_action_completed", response.body
    assert_match "GitHub github.comment: completed", response.body
  end

  test "the ledger page lists failures with their reason" do
    approval = build_approval(kind: "comment", body: "Nice")
    approval.decide!(decision: "approved", by: users(:david))
    memberships(:bender_watercooler).destroy!
    perform_enqueued_jobs only: Github::PerformAgentActionJob

    sign_in :david
    get agent_events_url(@agent)

    assert_response :success
    assert_match "GitHub github.comment: failed", response.body
    assert_match "Agent is no longer a member of the room", response.body
  end

  private
    def bearer_headers
      { "Authorization" => "Bearer #{@secret}" }
    end

    def build_approval(kind:, body: nil, reviewers: nil)
      action = Github::AgentPullRequestAction.new(
        pull_request: @pull_request, kind: kind, body: body, reviewers: reviewers
      )
      assert action.valid?, action.errors.full_messages.to_sentence
      AgentApproval.create!(
        agent: @agent, room: @room, action: action.action_name,
        summary: action.summary, payload: action.payload_json
      )
    end

    def create_agent_with_secret(name)
      bot = User.create_bot!(name: name)
      agent = bot.create_agent!(kind: :workspace, owner: users(:david))
      @room.memberships.grant_to(bot)
      _, secret = AgentCredential.create_with_secret!(agent: agent, name: "delivery", created_by: users(:david))
      [ agent, secret ]
    end
end
