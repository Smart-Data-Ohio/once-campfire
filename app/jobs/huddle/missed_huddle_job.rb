class Huddle::MissedHuddleJob < ApplicationJob
  # Runs after the invitation wait. A recipient who obtained a grant since the
  # start joined the call, so their invitation is handled automatically.
  # Anything else, including the starter leaving before the wait elapsed, is a
  # missed call: the item keeps its read state but reads as missed.
  def perform(activity_item_id)
    item = ActivityItem.find_by(id: activity_item_id)
    return unless item&.event_type == "huddle_started" && !item.handled?

    grant = item.source if item.source_type == HuddleGrant.polymorphic_name
    return unless grant

    if recipient_joined_since?(item, grant)
      item.mark_handled!
    else
      item.update!(event_type: "huddle_missed")
    end
  end

  private
    def recipient_joined_since?(item, grant)
      HuddleGrant.where(room_id: grant.room_id, user_id: item.user_id)
        .where("created_at >= ?", item.created_at)
        .exists?
    end
end
