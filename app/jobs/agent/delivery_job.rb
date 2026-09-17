class Agent::DeliveryJob < ApplicationJob
  def perform(agent_event_id)
    event = AgentEvent.find_by(id: agent_event_id)
    Agent::Delivery.perform(event) if event
  end
end
