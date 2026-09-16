class AgentsController < ApplicationController
  allow_agent_access only: :me

  def me
    no_store_response!

    agent = Current.agent || Current.user.agent

    if agent
      render json: agent_payload(agent)
    else
      head :not_found
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
        description: agent.description
      }.compact
    end
end
