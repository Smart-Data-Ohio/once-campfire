class Github::PerformAgentActionJob < ApplicationJob
  # Runs an approved agent GitHub write action. Re-checks everything at
  # perform time — the approval is still approved, the agent is active and
  # still belongs to the room with external_action, the PR thread mapping
  # is still present, and the agent's linked account is still usable — and
  # performs the action with the agent's own token otherwise. Every outcome
  # is recorded as a github_action_completed ledger row; a failed re-check
  # or GitHub error makes no GitHub request beyond the failed call itself.
  # Never raises for GitHub or re-check failures, and never retries.
  def perform(approval_id)
    approval = AgentApproval.find_by(id: approval_id)
    return unless approval&.github_action?

    agent = approval.agent
    room = approval.room

    if (reason = premature_failure_reason(approval, agent, room))
      return record_outcome(approval, agent, room, status: "failed", message: reason)
    end

    payload = parse_payload(approval.payload)
    pull_request = payload && Github::PullRequest.find_by(id: payload["pull_request_id"])
    unless pull_request && Github::PullRequestThread.exists?(github_pull_request_id: pull_request.id, room_id: room.id)
      return record_outcome(approval, agent, room, status: "failed",
        message: "The pull request is no longer discussed in this room")
    end

    action = Github::AgentPullRequestAction.from_payload(pull_request: pull_request, payload: payload)
    unless action.valid?
      return record_outcome(approval, agent, room, status: "failed", message: "Approval payload is invalid")
    end

    account = agent.user.github_connected_account
    unless account&.usable?
      return record_outcome(approval, agent, room, status: "failed",
        message: "Agent has no usable GitHub account")
    end

    begin
      client = Github::WriteClient.new(token: account.access_token)
    rescue ActiveRecord::Encryption::Errors::Decryption
      account.mark_disconnected!(GithubConnectedAccount::UNREADABLE_TOKEN_REASON)
      return record_outcome(approval, agent, room, status: "failed",
        message: GithubConnectedAccount::UNREADABLE_TOKEN_REASON)
    end

    begin
      response = action.perform(client)
    rescue Github::WriteClient::Unauthorized
      account.mark_disconnected!("GitHub rejected the linked token (401)")
      return record_outcome(approval, agent, room, status: "failed",
        message: "GitHub rejected the agent's linked token (401)")
    rescue Github::WriteClient::Refused, Github::WriteClient::Error => error
      return record_outcome(approval, agent, room, status: "failed", message: error.message)
    end

    url = response.is_a?(Hash) ? response["html_url"] : nil
    record_outcome(approval, agent, room, status: "completed", url: url)
  end

  private
    def premature_failure_reason(approval, agent, room)
      return "Approval is no longer approved" unless approval.status == "approved"
      return "Agent is suspended or deactivated" unless agent&.active?
      return "Room no longer exists" if room.nil?
      return "Agent is no longer a member of the room" unless Membership.exists?(user_id: agent.user_id, room_id: room.id)
      return "Agent no longer has the external_action capability" unless agent.can?(:external_action, room)

      nil
    end

    def parse_payload(stored)
      parsed = stored.is_a?(String) ? JSON.parse(stored) : nil
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def record_outcome(approval, agent, room, status:, message: nil, url: nil)
      event = agent.agent_events.create!(
        event_type: "github_action_completed",
        room: room,
        actor: approval.decided_by,
        outcome: "delivered",
        detail: (message if status == "failed"),
        metadata: {
          "approval_id" => approval.id,
          "action" => approval.action,
          "status" => status,
          "url" => url,
          "message" => message
        }.compact
      )
      post_webhook(event, agent)
      event
    end

    def post_webhook(event, agent)
      webhook = agent.user.webhook
      return unless webhook

      begin
        Agent::Delivery.post_github_action_webhook!(webhook, event, agent: agent)
      rescue StandardError => error
        Rails.logger.warn "Agent github action webhook delivery #{event.id} failed: #{error.class}"
      end
    end
end
