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

  test "unknown responses are rejected" do
    patch room_event_attendance_url(@room, @event), params: { response: "bogus" }

    assert_redirected_to room_event_path(@room, @event)
    assert_nil @event.response_for(users(:kevin))
  end
end
