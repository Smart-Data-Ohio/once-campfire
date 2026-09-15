module Message::Broadcasts
  def broadcast_create
    broadcast_append_to message_stream_target, :messages, target: [ message_stream_target, :messages ]
    broadcast_unread_room unless thread_message?
  end

  def broadcast_remove
    broadcast_remove_to message_stream_target, :messages
  end

  private
    # Fanned out to the room's members rather than published on one global stream, so
    # that the timing of activity in a room only reaches people who are in it.
    def broadcast_unread_room
      room.memberships.pluck(:user_id).each do |user_id|
        ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(user_id), { roomId: room.id }
      end
    end
end
