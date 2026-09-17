class Agents::MessagesController < MessagesController
  include AgentAuthorization

  allow_agent_access only: :create

  # Bearer-only endpoint. Forgery protection stays on: Bearer [REDACTED] already
  # bypass it through the Authentication concern, and a session-cookie request
  # that trips it gets the same 403 JSON that ensure_agent_token would return.
  rescue_from ActionController::InvalidAuthenticityToken, with: :reject_session_request

  # Re-declaring :set_room replaces the inherited except-create callback (same
  # filter name), so membership is checked as a before_action that halts with
  # 404 before authorization runs. Mirrors Messages::ByBotsController.
  before_action :set_room, only: :create
  before_action :ensure_agent_token, only: :create
  require_agent_capability :post_messages, only: :create

  # POST /rooms/:room_id/agents/messages (Bearer-only, JSON). Posts a root
  # message, or — with a top-level thread_id — a reply inside that thread
  # through ChannelThread#post_message!. The thread must belong to the room
  # (404 otherwise) and must not be locked (422). The response carries
  # thread_id, null for root messages.
  def create
    if params[:thread_id].present?
      create_thread_reply
    else
      super
      return if performed?

      render json: message_payload(@message).merge(thread_id: @message.thread_id), status: :created
    end
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
      render json: { error: "Forbidden: Bearer [REDACTED] token required" }, status: :forbidden
    end

    def create_thread_reply
      thread = @room.channel_threads.find_by(id: params[:thread_id])
      return head :not_found unless thread

      if thread.locked?
        render json: { error: "This thread is locked" }, status: :unprocessable_entity
        return
      end

      @message = thread.post_message!(
        creator: Current.user,
        attributes: thread_message_params,
        drive_file_ids: validated_drive_file_ids!
      )
      @message.broadcast_create

      render json: message_payload(@message).merge(thread_id: @message.thread_id), status: :created
    rescue ActiveRecord::RecordInvalid => error
      render_record_invalid(error)
    rescue ChannelThread::LockedError => error
      render json: { error: error.message }, status: :unprocessable_entity
    end

    # Thread replies take the same message fields as root posts, but a reply
    # target stays a plain id: the model validates that it lives in the same
    # conversation. Mirrors ChannelThreadMessagesController.
    def thread_message_params
      permitted = params.require(:message).permit(
        :body, :attachment, :client_message_id, :markdown_source,
        :reply_to_message_id, :reply_notify_author, drive_file_ids: []
      )
      permitted.delete(:drive_file_ids)

      if permitted.key?(:markdown_source) && !permitted[:markdown_source].nil?
        permitted.delete(:body)
      end

      permitted[:reply_to_message_id] = permitted[:reply_to_message_id].presence if permitted.key?(:reply_to_message_id)
      if permitted.key?(:reply_notify_author)
        permitted[:reply_notify_author] = ActiveModel::Type::Boolean.new.cast(permitted[:reply_notify_author])
      end
      permitted.to_h.symbolize_keys
    end
end
