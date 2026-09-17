require "test_helper"

class Event::ReminderDispatcherTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @organizer = users(:david)
    @event = @room.events.create!(
      organizer: @organizer, title: "Standup", starts_at: 10.minutes.from_now, time_zone: "UTC"
    )
    @event.attendances.create!(user: users(:jason), response: :going)
    @event.attendances.create!(user: users(:jz), response: :maybe)
    @event.attendances.create!(user: users(:kevin), response: :declined)
  end

  test "a due event reminds each going and maybe attendee once and enqueues push" do
    assert_enqueued_with(job: Event::ReminderPushJob, args: [ @event ]) do
      Event::ReminderDispatcher.dispatch_due!
    end

    assert_not_nil @event.reload.reminded_at

    [ @organizer, users(:jason), users(:jz) ].each do |attendee|
      items = ActivityItem.where(user: attendee, source: @event)
      assert_equal 1, items.count
      assert_equal "event_reminder", items.first.event_type
      assert_predicate items.first, :unread?
    end
  end

  test "members with notifications off keep their invitation and get no reminder" do
    memberships(:jason_designers).update!(involvement: "nothing")

    Event::ReminderDispatcher.dispatch_due!

    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: @event).event_type
    assert_equal "event_reminder", ActivityItem.find_by!(user: users(:jz), source: @event).event_type
  end

  test "an attendee with reminders switched off keeps the invitation while others are reminded" do
    users(:jason).update!(inbox_preferences: { "event_reminders" => false })

    assert_enqueued_with(job: Event::ReminderPushJob, args: [ @event ]) do
      Event::ReminderDispatcher.dispatch_due!
    end

    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: @event).event_type
    assert_equal "event_reminder", ActivityItem.find_by!(user: users(:jz), source: @event).event_type

    @event.update_with_announcement!({ starts_at: 2.days.from_now }, actor: @organizer)
    assert_equal "event_update", ActivityItem.find_by!(user: users(:jason), source: @event).event_type
  end

  test "declined attendees keep their invitation and get no reminder" do
    Event::ReminderDispatcher.dispatch_due!

    kevin_item = ActivityItem.find_by!(user: users(:kevin), source: @event)
    assert_equal "event_invitation", kevin_item.event_type
  end

  test "cancelled events are skipped" do
    @event.cancel!(actor: @organizer)
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: Event::ReminderPushJob do
      Event::ReminderDispatcher.dispatch_due!
    end

    assert_nil @event.reload.reminded_at
    assert_equal "event_cancelled", ActivityItem.find_by!(user: users(:jason), source: @event).event_type
  end

  test "only events starting soon are due" do
    @event.update!(starts_at: 2.days.from_now)

    assert_no_enqueued_jobs only: Event::ReminderPushJob do
      Event::ReminderDispatcher.dispatch_due!
    end

    assert_nil @event.reload.reminded_at
    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: @event).event_type
  end

  test "recently started events are still reminded but old ones are not" do
    @event.update!(starts_at: 30.minutes.ago)
    old_event = @room.events.create!(
      organizer: @organizer, title: "Old standup", starts_at: 2.hours.ago, time_zone: "UTC"
    )

    Event::ReminderDispatcher.dispatch_due!

    assert_not_nil @event.reload.reminded_at
    assert_equal "event_reminder", ActivityItem.find_by!(user: users(:jason), source: @event).event_type
    assert_nil old_event.reload.reminded_at
    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: old_event).event_type
  end

  test "a second run creates nothing" do
    Event::ReminderDispatcher.dispatch_due!
    clear_enqueued_jobs

    assert_no_difference -> { ActivityItem.where(source: @event).count } do
      assert_no_enqueued_jobs only: Event::ReminderPushJob do
        Event::ReminderDispatcher.dispatch_due!
      end
    end
  end

  test "one failing event does not stop the others" do
    other = @room.events.create!(
      organizer: @organizer, title: "Other standup", starts_at: 10.minutes.from_now, time_zone: "UTC"
    )
    Event.any_instance.stubs(:remind_attendees!).raises(RuntimeError).then.returns(nil)

    Event::ReminderDispatcher.dispatch_due!

    assert_nil @event.reload.reminded_at
    assert_not_nil other.reload.reminded_at
  end
end
