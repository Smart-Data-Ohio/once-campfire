require "test_helper"

class EventAttendanceTest < ActiveSupport::TestCase
  setup do
    @event = events(:launch_party)
  end

  test "a member holds a single response per event" do
    attendance = @event.attendances.find_by!(user: users(:jason))

    assert_equal "maybe", attendance.response
    attendance.update!(response: :going)
    assert_equal "going", attendance.reload.response

    assert_raises ActiveRecord::RecordInvalid do
      @event.attendances.create!(user: users(:jason), response: :maybe)
    end
  end

  test "rejects unknown responses" do
    assert_raises ArgumentError do
      @event.attendances.build(user: users(:kevin), response: "bogus")
    end
  end

  test "rejects bots, non-members, and responses to cancelled events" do
    assert_not @event.attendances.build(user: users(:bender), response: :going).valid?

    outsider = User.create!(name: "Outsider", email_address: "outsider@example.test", password: "secret123456")
    assert_not @event.attendances.build(user: outsider, response: :going).valid?

    cancelled = events(:retro)
    assert_not cancelled.attendances.build(user: users(:david), response: :going).valid?
  end
end
