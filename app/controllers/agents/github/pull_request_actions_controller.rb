class Agents::Github::PullRequestActionsController < ApplicationController
  allow_agent_access only: :create

  before_action :ensure_agent_token, only: :create
  before_action :set_room, only: :create
  before_action :set_pull_request_and_thread, only: :create
  before_action :ensure_external_action, only: :create
  before_action :ensure_agent_github_account, only: :create

  # POST /rooms/:room_id/agents/github/pull_request_actions (Bearer-only,
  # JSON). Requests a pull-request write action — comment, approve,
  # request_changes, or request_review — as the agent's own linked GitHub
  # account. Never calls GitHub: it creates an AgentApproval for a human
  # decider, and the action only runs when the request is approved. A
  # repeated external_id returns the existing row with 200, like
  # POST /agents/approvals.
  def create
    no_store_response!

    agent = Current.agent

    if params[:external_id].present?
      existing = AgentApproval.where(agent_id: agent.id, external_id: params[:external_id].to_s).first
      if existing
        existing.expire_if_due!
        render json: approval_created_payload(existing), status: :ok
        return
      end
    end

    action = Github::AgentPullRequestAction.new(
      pull_request: @pull_request,
      kind: params[:kind].to_s,
      body: params[:body],
      reviewers: params[:reviewers]
    )
    unless action.valid?
      render json: { errors: action.errors.to_hash }, status: :unprocessable_entity
      return
    end

    approval = AgentApproval.new(
      agent: agent,
      room: @room,
      agent_credential: current_credential,
      action: action.action_name,
      summary: action.summary,
      payload: action.payload_json,
      external_id: params[:external_id].presence
    )

    if approval.save
      render json: approval_created_payload(approval), status: :accepted
    else
      render json: { error: approval.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # Two identical requests raced past the replay lookup; the loser
    # answers with the winner's row exactly like a replay.
    existing = AgentApproval.find_by!(agent_id: agent.id, external_id: params[:external_id].to_s)
    existing.expire_if_due!
    render json: approval_created_payload(existing), status: :ok
  end

  private
    def ensure_agent_token
      unless authenticated_by.agent_token? && Current.agent
        render json: { error: "Forbidden: Bearer agent token required" }, status: :forbidden
      end
    end

    def set_room
      @room = Current.user.rooms.find_by(id: params[:room_id])

      head :not_found unless @room
    end

    def set_pull_request_and_thread
      @pull_request = Github::PullRequest.find_by(id: params[:pull_request_id])
      @thread_mapping = @pull_request &&
        Github::PullRequestThread.find_by(pull_request: @pull_request, room: @room)

      head :not_found unless @pull_request && @thread_mapping
    end

    def ensure_external_action
      unless Current.agent.can?(:external_action, @room)
        render json: { error: "Forbidden: agent lacks external_action capability" }, status: :forbidden
      end
    end

    def ensure_agent_github_account
      @github_account = Current.agent.user.github_connected_account

      unless @github_account&.usable?
        render json: { error: "Agent has no usable GitHub account" }, status: :unprocessable_entity
      end
    end

    def current_credential
      scheme, token = request.authorization.to_s.split(" ", 2)
      return nil unless scheme&.casecmp?("Bearer") && token.present?

      AgentCredential.find_by(token_digest: AgentCredential.digest(token.strip))
    end

    def approval_created_payload(approval)
      {
        id: approval.id,
        status: approval.effective_status,
        expires_at: approval.expires_at&.utc
      }.compact
    end
end
