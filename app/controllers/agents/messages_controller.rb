class Agents::MessagesController < MessagesController
  include AgentAuthorization

  allow_agent_access only: :create

  # Bearer-only endpoint. Forgery protection stays on: Bearer requests already
  # bypass it through the Authentication concern, and a session-cookie request
  # that trips it gets the same 403 JSON that ensure_agent_token would return.
  rescue_from ActionController::InvalidAuthenticityToken, with: :reject_session_request

  # Re-declaring :set_room replaces the inherited except-create callback (same
  # filter name), so membership is checked as a before_action that halts with
  # 404 before authorization runs. Mirrors Messages::ByBotsController.
  before_action :set_room, only: :create
  before_action :ensure_agent_token, only: :create
  require_agent_capability :post_messages, only: :create

  def create
    super
    return if performed?

    render json: message_payload(@message), status: :created
  end

  private
    def set_room
      @room = Current.user.rooms.find_by(id: params[:room_id])

      head :not_found unless @room
    end

    def ensure_agent_token
      reject_session_request unless authenticated_by.agent_token?
    end

    def reject_session_request
      render json: { error: "Forbidden: Bearer agent token required" }, status: :forbidden
    end
end
