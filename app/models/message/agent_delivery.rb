module Message::AgentDelivery
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_agent_deliveries
  end

  private
    def enqueue_agent_deliveries
      Agent::Delivery.enqueue_for_message(self)
    end
end
