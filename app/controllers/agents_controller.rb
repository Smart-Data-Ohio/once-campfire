class AgentsController < ApplicationController
  allow_agent_access only: %i[ me update ]

  def me
    no_store_response!

    agent = Current.agent || Current.user.agent

    if agent
      render json: agent_payload(agent)
    else
      head :not_found
    end
  end

  # PATCH /agents/me (Bearer-only, JSON). The agent reports its own status
  # and note. Only those two attributes are assignable; everything else in
  # the body is ignored.
  def update
    no_store_response!

    unless authenticated_by.agent_token? && Current.agent
      render json: { error: "Forbidden: Bearer [REDACTED] token required" }, status: :forbidden
      return
    end

    agent = Current.agent
    agent.status = params[:status] if params.key?(:status)
    agent.status_note = params[:status_note] if params.key?(:status_note)

    if agent.save
      render json: agent_payload(agent)
    else
      render json: { error: agent.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private
    def agent_payload(agent)
      {
        id: agent.id,
        kind: agent.kind,
        name: agent.user.name,
        user_id: agent.user_id,
        owner: agent.owner ? { id: agent.owner.id, name: agent.owner.name } : nil,
        provider: agent.provider,
        runtime: agent.runtime,
        description: agent.description,
        status: agent.status,
        status_note: agent.status_note,
        status_changed_at: agent.status_changed_at,
        last_seen_at: agent.last_seen_at
      }.compact
    end
end
