class TypingNotificationsChannel < RoomChannel
  def subscribed
    @room = find_room
    @conversation = if @room && params[:thread_id].present?
      @room.channel_threads.find_by(id: params[:thread_id])
    else
      @room
    end

    @conversation ? stream_for(@conversation) : reject
  end

  def start(data)
    broadcast_typing :start
  end

  def stop(data)
    broadcast_typing :stop
  end

  private
    def broadcast_typing(action)
      return unless @conversation && current_user.rooms.exists?(id: @room.id)
      return if @conversation.is_a?(ChannelThread) && !@room.channel_threads.exists?(id: @conversation.id)

      broadcast_to @conversation, action: action, user: current_user_attributes
    end

    def current_user_attributes
      current_user.slice(:id, :name)
    end
end
