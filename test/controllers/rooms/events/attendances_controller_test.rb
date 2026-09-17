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
end
