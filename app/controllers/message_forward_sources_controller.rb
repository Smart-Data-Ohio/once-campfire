class MessageForwardSourcesController < ApplicationController
  before_action :set_message

  # This response is deliberately per-viewer and never enters the message
  # fragment/broadcast path. A forward can remain visible after its original
  # becomes unavailable to a recipient, but that recipient must not learn an
  # original message id, author, room, or URL.
  def show
    no_store_response!
    source = @message.forwarded_from_message

    render json: {
      source: if source && Current.user.reachable_messages.where(id: source.id).exists?
        { url: message_permalink_url(source) }
              end
    }
  end

  alias forward_source show

  private
    def set_message
      message_id = params[:message_id] || params[:id]
      @message = Current.user.reachable_messages.find(message_id)

      return unless params[:room_id].present?

      room = Current.user.rooms.find(params[:room_id])
      raise ActiveRecord::RecordNotFound unless @message.room_id == room.id
      if params[:thread_id].present?
        raise ActiveRecord::RecordNotFound unless @message.thread_id == params[:thread_id].to_i
      elsif @message.thread_id.present?
        raise ActiveRecord::RecordNotFound
      end
    end
end
