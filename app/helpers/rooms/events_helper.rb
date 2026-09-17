module Rooms::EventsHelper
  # The event's own wall-clock time and zone abbreviation, printed next to
  # the browser-localized <time> so the scheduled zone is always visible.
  def event_zone_label(event)
    zone = event.time_zone.presence || "UTC"
    starts = event.starts_at.in_time_zone(zone)
    label = starts.strftime("%-I:%M %p")
    label += "\u2013#{event.ends_at.in_time_zone(zone).strftime("%-I:%M %p")}" if event.ends_at.present?
    "(#{label} #{starts.strftime("%Z")})"
  end

  def recurrence_phrase(rule)
    Event::Recurrence.phrase(rule)
  end

  def recurrence_label(rule)
    Event::Recurrence.label(rule)
  end

  def recurrence_until_text(date)
    date.strftime("%B %-d, %Y")
  end

  def recurrence_rule_options
    [ [ "Daily", "daily" ], [ "Weekly", "weekly" ], [ "Every two weeks", "biweekly" ], [ "Monthly", "monthly" ] ]
  end
end
