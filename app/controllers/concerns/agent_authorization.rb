module AgentAuthorization
  extend ActiveSupport::Concern

  class_methods do
    def require_agent_capability(capability, **options)
      before_action(**options) { ensure_agent_capability(capability) }
    end
  end

  private
    # Enforces room-scoped capability grants for agent-authenticated requests
    # (legacy bot keys and Bearer agent tokens). Human session requests pass
    # through; room membership is checked separately by each controller with
    # a 404. Bots without an Agent row are treated as legacy and allowed.
    # Reads the database on every request; no caching.
    def ensure_agent_capability(capability)
      return unless agent_authenticated_request?
      return if performed?

      agent = Current.agent || Current.user&.agent
      return if agent.nil?

      room = capability_check_room
      return if room.nil?

      unless agent.can?(capability, room)
        render json: { error: "Forbidden: agent lacks #{capability} capability" }, status: :forbidden
      end
    end

    def agent_authenticated_request?
      authenticated_by.bot_key? || authenticated_by.agent_token? || Current.agent.present? || Current.user&.bot?
    end

    def capability_check_room
      return @room if defined?(@room) && @room.present?
      return @message.room if defined?(@message) && @message.present?

      Room.find_by(id: params[:room_id]) if params[:room_id].present?
    end
end
