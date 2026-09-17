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

  # Events a message renders cards for. References only ever point at the
  # message's own room's events (Event::ReferenceSync), so the list is the
  # same for every viewer and for card broadcasts, which render outside a
  # request with no viewer at all.
  def event_cards_for(message)
    # Sorting in Ruby rather than with an `order` scope, because applying a
    # scope to an association builds a fresh relation and so ignores the rows
    # `with_rendering_details` already preloaded — one extra query per message
    # rendered. (Same reason `ordered_boosts` exists.)
    # Referenced events always belong to the message's own room (see
    # Event::ReferenceSync), so no per-viewer membership filter is needed.
    message.events.sort_by { |event| [ event.starts_at, event.id ] }
  end

  # The lazy attendance frame inside an event card. The message id keeps the
  # frame unique when one event is linked from several messages; the
  # attendances controller rebuilds the same id from its message_id param so
  # frame responses swap into the frame that requested them.
  def event_attendance_frame_id(event, message_id)
    dom_id(event, "response_for_message_#{message_id}")
  end
end
