module WorkThreadLinksHelper
  # Container ids are per context so the panel frame, the thread page
  # header, and the Work list row can share one stream response: targets
  # absent from the current page are ignored.
  def work_thread_links_box_id(thread, context)
    "work-thread-links-#{context}-#{thread.id}"
  end

  def work_thread_links_status_id(thread, context)
    "work-thread-links-#{context}-status-#{thread.id}"
  end

  def work_thread_links_panel_frame_id
    "thread-panel-work-links"
  end

  def work_thread_link_label(link)
    case link.kind
    when "pull_request"
      pull_request = link.github_pull_request
      "pull request #{pull_request.full_name}##{pull_request.number}"
    when "event"
      "event #{link.event.title}"
    when "drive_file"
      "Drive file #{link.title.presence || link.url}"
    end
  end

  def work_thread_link_event_option_label(event)
    "#{event.title} — #{event.starts_at.in_time_zone(event.time_zone).strftime("%b %-d, %Y, %-I:%M %p")}"
  end
end
