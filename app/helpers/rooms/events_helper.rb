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

  # Grouped options for the Where select: the current user's voice and Stage
  # channels, plus the event's current venue when the editor (an
  # administrator, or an organizer who has since left) cannot see it, so an
  # unrelated edit round-trips the stored venue instead of clearing it.
  def event_venue_options(event)
    venues = Current.user.rooms.where(type: %w[ Rooms::Voice Rooms::Stage ]).ordered.to_a
    venues << event.venue if event.venue.present? && venues.none? { |venue| venue.id == event.venue.id }

    [
      [ "Voice", venues.select(&:voice?).map { |venue| [ venue.name, venue.id ] } ],
      [ "Stage", venues.select(&:stage?).map { |venue| [ venue.name, venue.id ] } ]
    ].reject { |_, options| options.empty? }
  end

  # Memoized per request so event lists do not query memberships per row.
  def venue_member?(venue)
    @venue_room_ids ||= Current.user.room_ids.to_set
    @venue_room_ids.include?(venue.id)
  end
end
