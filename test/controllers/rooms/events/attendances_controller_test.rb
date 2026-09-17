require "test_helper"

class Rooms::Events::AttendancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:designers)
    @event = events(:launch_party)
    sign_in :kevin
  end

  test "a member can respond and change their response" do
    patch room_event_attendance_url(@room, @event), params: { response: "going" }

    assert_redirected_to room_event_path(@room, @event)
    assert_equal "going", @event.response_for(users(:kevin))

    patch room_event_attendance_url(@room, @event), params: { response: "declined" }

    assert_redirected_to room_event_path(@room, @event)
    assert_equal "declined", @event.response_for(users(:kevin))
    assert_equal 1, @event.attendances.where(user: users(:kevin)).count
  end

  test "non-members get a 404" do
    memberships(:kevin_designers).destroy!

    patch room_event_attendance_url(@room, @event), params: { response: "going" }

    assert_response :not_found
    assert_nil @event.response_for(users(:kevin))
  end

  test "bots are denied" do
    delete session_url

    patch room_event_attendance_url(@room, @event, bot_key: users(:bender).bot_key), params: { response: "going" }

    assert_response :forbidden
  end

  test "cancelled events reject responses" do
    @event.cancel!(actor: users(:david))

    patch room_event_attendance_url(@room, @event), params: { response: "going" }

    assert_redirected_to room_event_path(@room, @event)
    assert_nil @event.response_for(users(:kevin))
  end

  test "a response on the first event of a series is copied to every future occurrence" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a

    patch room_event_attendance_url(@room, head), params: { response: "going" }

    assert_redirected_to room_event_path(@room, head)
    occurrences.each do |occurrence|
      assert_equal "going", occurrence.response_for(users(:kevin))
    end
  end

  test "a later response stays local unless apply to all future is checked" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a

    patch room_event_attendance_url(@room, occurrences.second), params: { response: "going" }

    assert_redirected_to room_event_path(@room, occurrences.second)
    assert_nil occurrences.first.response_for(users(:kevin))
    assert_equal "going", occurrences.second.response_for(users(:kevin))
    assert_nil occurrences.third.response_for(users(:kevin))

    patch room_event_attendance_url(@room, occurrences.second),
      params: { response: "maybe", apply_to_future: "1" }

    assert_redirected_to room_event_path(@room, occurrences.second)
    assert_nil occurrences.first.response_for(users(:kevin))
    assert_equal "maybe", occurrences.second.response_for(users(:kevin))
    assert_equal "maybe", occurrences.third.response_for(users(:kevin))
  end

  test "show offers apply to all future on later occurrences with a successor" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a

    get room_event_url(@room, occurrences.second)

    assert_response :success
    assert_includes response.body, "Apply to all future occurrences"

    get room_event_url(@room, occurrences.third)

    assert_response :success
    assert_not_includes response.body, "Apply to all future occurrences"

    get room_event_url(@room, head)

    assert_response :success
    assert_not_includes response.body, "Apply to all future occurrences"
    assert_includes response.body, "every future occurrence in this series"
  end

  test "unknown responses are rejected" do
    patch room_event_attendance_url(@room, @event), params: { response: "bogus" }

    assert_redirected_to room_event_path(@room, @event)
    assert_nil @event.response_for(users(:kevin))
  end

  test "show renders the attendance frame with the response controls for members" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-show"
    )

    get room_event_attendance_url(@room, @event, message_id: message.id)

    assert_response :success
    assert_select "turbo-frame#response_for_message_#{message.id}_event_#{@event.id}", count: 1
    assert_select ".event-card__current", text: /No response yet/
    assert_select ".event-card__counts", text: /1 going, 1 maybe/
    assert_select "form button", text: "Going"
    assert_select "form button", text: "Maybe"
    assert_select "form button", text: "Declined"
  end

  test "show 404s for non-members" do
    memberships(:kevin_designers).destroy!
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-show-denied"
    )

    get room_event_attendance_url(@room, @event, message_id: message.id)

    assert_response :not_found
  end

  test "show offers apply to all future occurrences on the series head and hides it on the last occurrence" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    occurrences = head.series_events.to_a
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{head.id}",
      client_message_id: "evt-frame-series"
    )

    get room_event_attendance_url(@room, head, message_id: message.id)

    assert_response :success
    assert_select "input[name=apply_to_future]", count: 1

    get room_event_attendance_url(@room, occurrences.last, message_id: message.id)

    assert_response :success
    assert_select "input[name=apply_to_future]", count: 0
  end

  test "show reports the closed state for cancelled events" do
    @event.cancel!(actor: users(:david))
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-cancelled"
    )

    get room_event_attendance_url(@room, @event, message_id: message.id)

    assert_response :success
    assert_select "form button", text: "Going", count: 0
    assert_select ".event-card__closed", text: /cancelled/
  end

  test "responding from the frame re-renders the frame instead of redirecting" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-update"
    )
    frame_id = "response_for_message_#{message.id}_event_#{@event.id}"

    patch room_event_attendance_url(@room, @event),
      params: { response: "going", message_id: message.id },
      headers: { "Turbo-Frame" => frame_id }

    assert_response :success
    assert_equal "going", @event.response_for(users(:kevin))
    assert_select "turbo-frame##{frame_id}", count: 1
    assert_select ".event-card__current strong", text: "Going"
    assert_select ".event-card__counts", text: /2 goings, 1 maybe/
  end

  test "a frame response from a non-member 404s" do
    memberships(:kevin_designers).destroy!
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-update-denied"
    )

    patch room_event_attendance_url(@room, @event),
      params: { response: "going", message_id: message.id },
      headers: { "Turbo-Frame" => "response_for_message_#{message.id}_event_#{@event.id}" }

    assert_response :not_found
    assert_nil @event.response_for(users(:kevin))
  end

  test "a frame response with an unknown choice re-renders the frame with an alert" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-update-bogus"
    )

    patch room_event_attendance_url(@room, @event),
      params: { response: "bogus", message_id: message.id },
      headers: { "Turbo-Frame" => "response_for_message_#{message.id}_event_#{@event.id}" }

    assert_response :success
    assert_nil @event.response_for(users(:kevin))
    assert_select ".event-card__alert", text: /going, maybe, or declined/
  end

  test "a frame response to a cancelled event re-renders the frame with an alert" do
    @event.cancel!(actor: users(:david))
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-frame-update-cancelled"
    )

    patch room_event_attendance_url(@room, @event),
      params: { response: "going", message_id: message.id },
      headers: { "Turbo-Frame" => "response_for_message_#{message.id}_event_#{@event.id}" }

    assert_response :success
    assert_nil @event.response_for(users(:kevin))
    assert_select ".event-card__alert", text: /no longer open for responses/
  end
end
