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
