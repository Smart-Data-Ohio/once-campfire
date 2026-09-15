class ActivityChannel < ApplicationCable::Channel
  def self.stream_name_for(user_id)
    "user_#{user_id}_activity"
  end

  def subscribed
    if ActivityItem.active_human?(current_user)
      stream_from self.class.stream_name_for(current_user.id)
    else
      reject
    end
  end
end
