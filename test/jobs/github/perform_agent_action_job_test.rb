require "test_helper"

class Github::PerformAgentActionJobTest < ActiveJob::TestCase
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "agent-action-job-pr-12"
    )
    @pull_request = message.github_pull_requests.first
    thread = ChannelThread.create!(room: @room, creator: users(:david), parent_message: message)
    ThreadMembership.join!(thread, users(:david))
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: thread)

    @grant = AgentGrant.create!(agent: @agent, room: @room, granted_by: users(:david), capability: "external_action")
    @account = GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "agent-token-abc")

    @original_token = ENV["GITHUB_TOKEN"]
    ENV["GITHUB_TOKEN"] = "workspace-token"
  end

  teardown do
    ENV["GITHUB_TOKEN"] = @original_token
  end

  test "approving a github action enqueues the job, denying does not" do
    approvable = build_approval(kind: "comment", body: "Nice")

    assert_enqueued_with(job: Github::PerformAgentActionJob, args: [ approvable.id ]) do
      approvable.decide!(decision: "approved", by: users(:david))
    end

    deniable = build_approval(kind: "comment", body: "Nope")
    assert_no_enqueued_jobs only: Github::PerformAgentActionJob do
      deniable.decide!(decision: "denied", by: users(:david))
    end
  end

  test "approving a non-github action enqueues nothing" do
    approval = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")

    assert_no_enqueued_jobs only: Github::PerformAgentActionJob do
      approval.decide!(decision: "approved", by: users(:david))
    end
  end

  test "an approved comment posts with the agent token and records completion" do
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .with(body: { body: "Nice work" }.to_json)
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12#issuecomment-1" }.to_json)
    approval = approve!(build_approval(kind: "comment", body: "Nice work"))

    assert_no_difference -> { Message.count } do
      Github::PerformAgentActionJob.perform_now(approval.id)
    end

    assert_requested stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    event = completion_event_for(approval)
    assert_equal "delivered", event.outcome
    assert_equal @room, event.room
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

  test "an approved approve posts the review with the agent token" do
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .with(body: { event: "APPROVE" }.to_json)
      .to_return(status: 200, body: { html_url: "https://github.com/rails/rails/pull/12#pullrequestreview-2" }.to_json)
    approval = approve!(build_approval(kind: "approve"))

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_requested stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    assert_equal "completed", completion_event_for(approval).metadata["status"]
    assert_equal "https://github.com/rails/rails/pull/12#pullrequestreview-2",
      completion_event_for(approval).metadata["url"]
  end

  test "approved request_changes posts the review body" do
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .with(body: { event: "REQUEST_CHANGES", body: "Fix the typo" }.to_json)
      .to_return(status: 200, body: { html_url: "https://github.com/rails/rails/pull/12#pullrequestreview-3" }.to_json)
    approval = approve!(build_approval(kind: "request_changes", body: "Fix the typo"))

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_requested stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    assert_equal "completed", completion_event_for(approval).metadata["status"]
  end

  test "approved request_review posts the reviewer logins" do
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .with(body: { reviewers: %w[ alice bob ] }.to_json)
      .to_return(status: 201, body: { html_url: "https://github.com/rails/rails/pull/12" }.to_json)
    approval = approve!(build_approval(kind: "request_review", reviewers: %w[ alice bob ]))

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_requested stub, headers: { "Authorization" => "Bearer [REDACTED]" }
    assert_equal "completed", completion_event_for(approval).metadata["status"]
    assert_equal "https://github.com/rails/rails/pull/12", completion_event_for(approval).metadata["url"]
  end

  test "a denied approval makes no request and records failure" do
    approval = build_approval(kind: "comment", body: "Nope")
    approval.decide!(decision: "denied", by: users(:david))

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Approval is no longer approved")
  end

  test "an expired approval makes no request and records failure" do
    approval = build_approval(kind: "comment", body: "Late")
    approval.update_columns(expires_at: 1.minute.ago)

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Approval is no longer approved")
  end

  test "a cancelled approval makes no request and records failure" do
    approval = build_approval(kind: "comment", body: "Never mind")
    approval.cancel_by_agent!

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Approval is no longer approved")
  end

  test "removed membership makes no request and records failure" do
    approval = approve!(build_approval(kind: "comment", body: "Hi"))
    memberships(:bender_watercooler).destroy!

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Agent is no longer a member of the room")
  end

  test "a revoked grant makes no request and records failure" do
    approval = approve!(build_approval(kind: "comment", body: "Hi"))
    @grant.revoke!

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Agent no longer has the external_action capability")
  end

  test "a suspended agent makes no request and records failure" do
    approval = approve!(build_approval(kind: "comment", body: "Hi"))
    @agent.update!(suspended_at: Time.current)

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Agent is suspended or deactivated")
  end

  test "a deleted thread mapping makes no request and records failure" do
    approval = approve!(build_approval(kind: "comment", body: "Hi"))
    Github::PullRequestThread.where(
      github_pull_request_id: @pull_request.id, room_id: @room.id
    ).delete_all

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "The pull request is no longer discussed in this room")
  end

  test "a disconnected account makes no request and records failure" do
    approval = approve!(build_approval(kind: "comment", body: "Hi"))
    @account.mark_disconnected!("GitHub rejected the linked token (401)")

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Agent has no usable GitHub account")
  end

  test "a destroyed account makes no request and records failure" do
    approval = approve!(build_approval(kind: "comment", body: "Hi"))
    @account.destroy!

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_requested :post, %r{api\.github\.com}
    assert_failed_with(approval, "Agent has no usable GitHub account")
  end

  test "a GitHub 401 disconnects the account and records failure" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)
    approval = approve!(build_approval(kind: "comment", body: "Hi"))

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_not_predicate @account.reload, :usable?
    assert_equal "GitHub rejected the linked token (401)", @account.disconnected_reason
    assert_failed_with(approval, "GitHub rejected the agent's linked token (401)")
  end

  test "a GitHub 403 records failure with GitHub's message" do
    stub_request(:post, "https://api.github.com/repos/rails/rails/issues/12/comments")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)
    approval = approve!(build_approval(kind: "comment", body: "Hi"))

    Github::PerformAgentActionJob.perform_now(approval.id)

    assert_predicate @account.reload, :usable?
    assert_failed_with(approval, "GitHub refused: Resource not accessible by personal access token")
  end

  test "a missing approval and a non-github approval are silent no-ops" do
    assert_nothing_raised_for_job(999_999_999)

    other = AgentApproval.create!(agent: @agent, room: @room, action: "deploy", summary: "Ship it")
    other.decide!(decision: "approved", by: users(:david))

    assert_no_difference -> { @agent.agent_events.where(event_type: "github_action_completed").count } do
      Github::PerformAgentActionJob.perform_now(other.id)
    end
    assert_not_requested :post, %r{api\.github\.com}
  end

  private
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

    def approve!(approval)
      approval.decide!(decision: "approved", by: users(:david))
      approval
    end

    def completion_event_for(approval)
      @agent.agent_events.where(event_type: "github_action_completed", outcome: "delivered").to_a
        .find { |event| event.metadata.is_a?(Hash) && event.metadata["approval_id"] == approval.id } ||
        raise(ActiveRecord::RecordNotFound, "missing github_action_completed event for approval #{approval.id}")
    end

    def assert_failed_with(approval, reason)
      event = completion_event_for(approval)
      assert_equal "failed", event.metadata["status"]
      assert_equal reason, event.metadata["message"]
      assert_equal "github.comment", event.metadata["action"]
      assert_nil event.metadata["url"]
      assert_equal "delivered", event.outcome
    end

    # perform_now returns normally for unknown ids; calling it plainly
    # proves it never raises.
    def assert_nothing_raised_for_job(approval_id)
      Github::PerformAgentActionJob.perform_now(approval_id)
    end
end
