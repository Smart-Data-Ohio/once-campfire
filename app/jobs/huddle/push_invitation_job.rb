class Huddle::PushInvitationJob < ApplicationJob
  def perform(activity_item_id)
    item = ActivityItem.find_by(id: activity_item_id)
    return unless item

    Huddle::InvitationPusher.new(activity_item: item).push
  end
end
