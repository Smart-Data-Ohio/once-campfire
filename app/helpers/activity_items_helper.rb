module ActivityItemsHelper
  def activity_item_source_path(item)
    source = item.source
    return activity_items_path unless source

    case source
    when Message
      if source.thread_message?
        room_path(source.room, thread: source.thread_id, message_id: source.id)
      else
        room_at_message_path(source.room, source)
      end
    when WorkThreadEvent
      thread = source.thread
      thread ? room_path(thread.room, thread: thread.id) : activity_items_path
    when HuddleGrant
      source.room ? room_path(source.room) : activity_items_path
    else
      activity_items_path
    end
  end

  def activity_item_event_label(item)
    case item.event_type
    when "mention"
      "Mention"
    when "reply"
      "Reply"
    when "thread_activity"
      "Followed thread"
    when "work_assignment"
      "Work assignment"
    when "work_update"
      "Work update"
    when "huddle_started"
      "Incoming huddle"
    when "huddle_missed"
      "Missed huddle"
    when "pr_review_request"
      "Review requested"
    else
      item.event_type.humanize
    end
  end

  def activity_item_source_label(item)
    source = item.source
    return "Unavailable source" unless source

    case source
    when Message
      if source.thread_message?
        "#{room_display_name(source.room)} · #{source.thread.name}"
      else
        room_display_name(source.room)
      end
    when WorkThreadEvent
      source.thread ? "#{room_display_name(source.thread.room)} · #{source.thread.name}" : "Unavailable thread"
    when HuddleGrant
      source.room ? room_display_name(source.room) : "Unavailable room"
    else
      source.class.name.humanize
    end
  end

  def activity_item_source_body(item)
    source = item.source
    return "This source is no longer available." unless source

    case source
    when Message
      source.plain_text_body
    when WorkThreadEvent
      changes = []
      if source.status_changed?
        changes << "Status: #{activity_item_work_status_label(source.from_status)} → #{activity_item_work_status_label(source.to_status)}"
      end
      if source.owner_changed?
        changes << "Owner: #{source.from_owner_name.presence || "unassigned"} → #{source.to_owner_name.presence || "unassigned"}"
      end
      changes.presence&.to_sentence || "Work thread updated"
    when HuddleGrant
      caller = source.user&.name || "Someone"
      if item.event_type == "huddle_missed"
        "You missed a huddle from #{caller}"
      else
        "#{caller} started a huddle"
      end
    else
      "Source updated"
    end
  end

  def activity_item_source_author(item)
    source = item.source
    case source
    when Message
      source.creator&.name
    when WorkThreadEvent
      source.actor&.name || "Work thread"
    when HuddleGrant
      source.user&.name
    end
  end

  def activity_item_work_status_label(status)
    status.present? ? status.humanize : "None"
  end
end
