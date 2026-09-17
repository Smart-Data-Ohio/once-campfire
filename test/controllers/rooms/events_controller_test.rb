require "test_helper"

class Rooms::EventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:designers)
    @event = events(:launch_party)
    sign_in :david
  end

  test "index lists upcoming, past, and cancelled events separately" do
    @room.events.create!(organizer: users(:david), title: "Old kickoff", starts_at: 2.days.ago, time_zone: "UTC")

    get room_events_url(@room)

    assert_response :success
    upcoming, rest = response.body.split("id=\"past-events\"", 2)
    past, cancelled = rest.split("id=\"cancelled-events\"", 2)
    assert_includes upcoming, "Launch party planning"
    assert_not_includes upcoming, "Old kickoff"
    assert_includes past, "Old kickoff"
    assert_includes cancelled, "Sprint retro"
  end

  test "show renders for members and 404s for non-members" do
    get room_event_url(@room, @event)

    assert_response :success
    assert_includes response.body, "Launch party planning"

    memberships(:david_designers).destroy!

    get room_event_url(@room, @event)

    assert_response :not_found
  end

  test "a member can create an event and members are invited" do
    assert_difference -> { Event.count } do
      post room_events_url(@room), params: {
        event: { title: "Demo day", description: "Show and tell", starts_at: "2026-09-25T15:30", time_zone: "America/New_York" }
      }
    end

    event = Event.order(:created_at).last
    assert_redirected_to room_event_path(@room, event)
    assert_equal users(:david), event.organizer
    assert_equal ActiveSupport::TimeZone["America/New_York"].parse("2026-09-25T15:30"), event.starts_at
    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: event).event_type
  end

  test "a member can create a repeating event with one invitation per member" do
    assert_difference -> { Event.count }, 3 do
      post room_events_url(@room), params: {
        event: {
          title: "Weekly planning", starts_at: "2026-09-25T15:30", time_zone: "America/New_York",
          recurrence_rule: "weekly", recurrence_until: "2026-10-09"
        }
      }
    end

    head = Event.where(title: "Weekly planning").order(:created_at).first
    assert_redirected_to room_event_path(@room, head)
    assert_equal head.id, head.series_id
    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size

    %i[ jason jz kevin ].each do |name|
      items = ActivityItem.where(user: users(name), source: occurrences)
      assert_equal 1, items.count
      assert_equal head.id, items.first.source_id
    end
  end

  test "create rejects a series above the occurrence cap" do
    assert_no_difference -> { Event.count } do
      post room_events_url(@room), params: {
        event: {
          title: "Too long", starts_at: "2026-09-25T15:30", time_zone: "UTC",
          recurrence_rule: "daily", recurrence_until: "2026-12-01"
        }
      }
    end

    assert_response :unprocessable_content
    assert_includes response.body, "pick an earlier end date"
  end

  test "index shows a series once with its repeat label and remaining count" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size

    get room_events_url(@room)

    assert_response :success
    upcoming = response.body.split("id=\"cancelled-events\"", 2).first.split("id=\"past-events\"", 2).first
    assert_equal 2, upcoming.scan("room-events__item\"").size
    assert_includes upcoming, "Weekly planning"
    assert_includes upcoming, "Repeats weekly"
    assert_includes upcoming, "3 occurrences remaining"
    assert_includes upcoming, room_event_path(@room, occurrences.first)
    assert_not_includes upcoming, room_event_path(@room, occurrences.second)
    assert_not_includes upcoming, room_event_path(@room, occurrences.third)
  end

  test "index lists past occurrences individually" do
    head = @room.events.create!(
      organizer: users(:david), title: "Old planning", starts_at: 10.days.ago, time_zone: "UTC",
      recurrence_rule: "daily", recurrence_until: Date.current - 8
    )
    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size

    get room_events_url(@room)

    assert_response :success
    _upcoming, rest = response.body.split("id=\"past-events\"", 2)
    occurrences.each do |occurrence|
      assert_includes rest, room_event_path(@room, occurrence)
    end
  end

  test "show renders the series banner with previous and next occurrence links" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a

    get room_event_url(@room, occurrences.second)

    assert_response :success
    assert_includes response.body, "Part of a series: repeats weekly until #{head.recurrence_until.strftime("%B %-d, %Y")}"
    assert_includes response.body, "Previous occurrence"
    assert_includes response.body, "Next occurrence"
    assert_includes response.body, room_event_path(@room, occurrences.first)
    assert_includes response.body, room_event_path(@room, occurrences.third)

    get room_event_url(@room, head)

    assert_response :success
    assert_includes response.body, "Part of a series"
    assert_includes response.body, "Next occurrence"
    assert_not_includes response.body, "Previous occurrence"
  end

  test "edit offers a scope on series occurrences and the rule only on the first event" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrence = head.series_events.second

    get edit_room_event_url(@room, occurrence)

    assert_response :success
    assert_includes response.body, "This event"
    assert_includes response.body, "This and following"
    assert_not_includes response.body, "event[recurrence_rule]"

    get edit_room_event_url(@room, head)

    assert_response :success
    assert_includes response.body, "This and following"
    assert_includes response.body, "event[recurrence_rule]"
    assert_includes response.body, "Repeat until"
  end

  test "updating this and following shifts later occurrences and notifies once per attendee" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning",
      starts_at: ActiveSupport::TimeZone["UTC"].local(2026, 9, 25, 15, 30),
      ends_at: ActiveSupport::TimeZone["UTC"].local(2026, 9, 25, 16, 30),
      time_zone: "UTC", recurrence_rule: "weekly", recurrence_until: Date.new(2026, 10, 9)
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")

    patch room_event_url(@room, head), params: {
      update_scope: "this_and_following",
      event: { title: "Weekly planning", starts_at: "2026-09-25T16:30", ends_at: "2026-09-25T17:30", time_zone: "UTC" }
    }

    assert_redirected_to room_event_path(@room, head)
    assert_equal ActiveSupport::TimeZone["UTC"].local(2026, 10, 2, 16, 30), occurrences.second.reload.starts_at
    assert_equal ActiveSupport::TimeZone["UTC"].local(2026, 10, 9, 16, 30), occurrences.third.reload.starts_at
    items = ActivityItem.where(user: users(:jason), source: occurrences)
    assert_equal 1, items.count
    assert_equal "event_update", items.first.event_type
    assert_equal head.id, items.first.source_id
  end

  test "updating without a scope leaves the rest of the series untouched" do
    starts_at = 2.days.from_now
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at:, ends_at: starts_at + 1.hour, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a

    patch room_event_url(@room, occurrences.second), params: {
      event: {
        title: "Renamed",
        starts_at: (occurrences.second.starts_at + 1.hour).strftime("%Y-%m-%dT%H:%M"),
        ends_at: (occurrences.second.ends_at + 1.hour).strftime("%Y-%m-%dT%H:%M"),
        time_zone: "UTC"
      }
    }

    assert_redirected_to room_event_path(@room, occurrences.second)
    assert_equal "Weekly planning", occurrences.first.reload.title
    assert_equal "Weekly planning", occurrences.third.reload.title
  end

  test "changing the rule away from the first event is rejected" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )

    patch room_event_url(@room, head.series_events.second), params: {
      update_scope: "this_and_following",
      event: { title: "Weekly planning", recurrence_rule: "daily" }
    }

    assert_response :unprocessable_content
    assert_includes response.body, "first event"
  end

  test "non-organizers cannot edit or cancel series occurrences" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrence = head.series_events.second
    sign_in :kevin

    get edit_room_event_url(@room, occurrence)
    assert_response :forbidden

    patch room_event_url(@room, occurrence), params: { event: { title: "Hijacked" } }
    assert_response :forbidden
    assert_equal "Weekly planning", occurrence.reload.title

    patch cancel_room_event_url(@room, occurrence), params: { cancel_scope: "this_and_following" }
    assert_response :forbidden
    assert_not_predicate occurrence.reload, :cancelled?
  end

  test "cancelling this and following cancels later occurrences with one item per attendee" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")

    patch cancel_room_event_url(@room, occurrences.second), params: { cancel_scope: "this_and_following" }

    assert_redirected_to room_event_path(@room, occurrences.second)
    assert_not_predicate occurrences.first.reload, :cancelled?
    assert_predicate occurrences.second.reload, :cancelled?
    assert_predicate occurrences.third.reload, :cancelled?
    items = ActivityItem.where(user: users(:jason), source: occurrences, event_type: "event_cancelled")
    assert_equal 1, items.count
    assert_equal occurrences.second.id, items.first.source_id
  end

  test "cancelling without a scope cancels only that occurrence" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a

    patch cancel_room_event_url(@room, occurrences.second)

    assert_redirected_to room_event_path(@room, occurrences.second)
    assert_not_predicate occurrences.first.reload, :cancelled?
    assert_predicate occurrences.second.reload, :cancelled?
    assert_not_predicate occurrences.third.reload, :cancelled?
  end

  test "create renders errors for invalid events" do
    assert_no_difference -> { Event.count } do
      post room_events_url(@room), params: { event: { title: "", starts_at: "", time_zone: "UTC" } }
    end

    assert_response :unprocessable_content
  end

  test "bots are denied" do
    delete session_url

    post room_events_url(@room, bot_key: users(:bender).bot_key), params: {
      event: { title: "Bot party", starts_at: "2026-09-25T15:30", time_zone: "UTC" }
    }

    assert_response :forbidden

    bot = users(:bender)
    bot.update!(email_address: "bender@example.test", password: "secret123456")
    sign_in bot

    get room_events_url(rooms(:watercooler))

    assert_response :forbidden
  end

  test "requires authentication" do
    delete session_url

    get room_events_url(@room)

    assert_redirected_to new_session_url
  end

  test "only the organizer or an administrator can edit" do
    sign_in :kevin

    get edit_room_event_url(@room, @event)
    assert_response :forbidden

    patch room_event_url(@room, @event), params: { event: { title: "Hijacked" } }
    assert_response :forbidden
    assert_equal "Launch party planning", @event.reload.title

    sign_in :jason

    get edit_room_event_url(@room, @event)
    assert_response :success
  end

  test "the organizer can update times and attendees are notified" do
    @event.attendances.create!(user: users(:kevin), response: :going)

    patch room_event_url(@room, @event), params: {
      event: { title: "Launch party planning", starts_at: "2026-09-26T15:30", ends_at: "", time_zone: "UTC" }
    }

    assert_redirected_to room_event_path(@room, @event)
    # Posted times are read in the event's own zone, not the posted one.
    assert_equal ActiveSupport::TimeZone["America/New_York"].parse("2026-09-26 15:30"), @event.reload.starts_at
    assert_equal "America/New_York", @event.time_zone
    assert_equal "event_update", ActivityItem.find_by!(user: users(:kevin), source: @event).event_type
  end

  test "saving the edit form from another time zone does not move the event" do
    @event.attendances.create!(user: users(:kevin), response: :going)
    # The form posts minute precision, as a browser would.
    @event.update_columns(starts_at: @event.starts_at.change(sec: 0), ends_at: @event.ends_at.change(sec: 0))
    original_starts_at = @event.starts_at
    zone = @event.time_zone

    assert_no_difference -> { ActivityItem.count } do
      patch room_event_url(@room, @event), params: {
        event: {
          title: "Launch party planning (renamed)",
          starts_at: original_starts_at.in_time_zone(zone).strftime("%Y-%m-%dT%H:%M"),
          ends_at: @event.ends_at.in_time_zone(zone).strftime("%Y-%m-%dT%H:%M"),
          time_zone: "Europe/Berlin"
        }
      }
    end

    assert_redirected_to room_event_path(@room, @event)
    @event.reload
    assert_equal "Launch party planning (renamed)", @event.title
    assert_equal original_starts_at.to_i, @event.starts_at.to_i
    assert_equal zone, @event.time_zone
  end

  test "show prints the scheduled zone next to the localized time" do
    get room_event_url(@room, @event)

    assert_response :success
    assert_select ".room-events__zone", text: /E[DS]T\)\z/
  end

  test "cancelled events cannot be edited" do
    @event.cancel!(actor: users(:david))

    get edit_room_event_url(@room, @event)
    assert_response :forbidden

    patch room_event_url(@room, @event), params: { event: { title: "Resurrected" } }
    assert_response :forbidden
    assert_equal "Launch party planning", @event.reload.title
  end

  test "non-organizers cannot cancel" do
    sign_in :kevin

    patch cancel_room_event_url(@room, @event)

    assert_response :forbidden
    assert_not_predicate @event.reload, :cancelled?
  end

  test "the organizer can cancel and cancelling twice is a no-op" do
    patch cancel_room_event_url(@room, @event)

    assert_redirected_to room_event_path(@room, @event)
    assert_predicate @event.reload, :cancelled?

    patch cancel_room_event_url(@room, @event)

    assert_redirected_to room_event_path(@room, @event)
    assert_predicate @event.reload, :cancelled?
  end

  test "show notes the Google Calendar copy when an entry exists for the viewer" do
    get room_event_url(@room, @event)

    assert_not_includes response.body, "Added to your Google Calendar"

    EventCalendarEntry.create!(event: @event, user: users(:david), google_event_id: SecureRandom.hex(16))

    get room_event_url(@room, @event)

    assert_includes response.body, "Added to your Google Calendar"
  end

  test "show hides another member's Google Calendar copy" do
    EventCalendarEntry.create!(event: @event, user: users(:jason), google_event_id: SecureRandom.hex(16))

    get room_event_url(@room, @event)

    assert_not_includes response.body, "Added to your Google Calendar"
  end
end
