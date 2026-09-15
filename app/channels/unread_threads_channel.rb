class UnreadThreadsChannel < ApplicationCable::Channel
  def self.stream_name_for(user_id)
    "user_#{user_id}_unread_threads"
  end

  def subscribed
    stream_from self.class.stream_name_for(current_user.id)
  end
end
