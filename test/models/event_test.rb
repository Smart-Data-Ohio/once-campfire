require "test_helper"

class EventTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @organizer = users(:david)
  end

  test "requires a title, start time, and time zone" do
    event = @room.events.build(organizer: @organizer, starts_at: 1.day.from_now, time_zone: "UTC")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :title
    assert_includes @room.events.build(organizer: @organizer, title: "No start", time_zone: "UTC").tap(&:validate).errors.attribute_names, :starts_at
    assert_includes @room.events.build(organizer: @organizer, title: "No zone", starts_at: 1.day.from_now).tap(&:validate).errors.attribute_names, :time_zone
  end

  test "rejects unknown time zones" do
    event = @room.events.build(organizer: @organizer, title: "Bad zone", starts_at: 1.day.from_now, time_zone: "Mars/Olympus")

    assert_not event.valid?
    assert_equal [ "is invalid" ], event.errors[:time_zone]
  end

  test "requires the end to follow the start" do
    starts_at = 1.day.from_now

    assert_not @room.events.build(organizer: @organizer, title: "Ends early", starts_at:, ends_at: starts_at - 1.hour, time_zone: "UTC").valid?
    assert_not @room.events.build(organizer: @organizer, title: "Ends same", starts_at:, ends_at: starts_at, time_zone: "UTC").valid?
    assert @room.events.build(organizer: @organizer, title: "No end", starts_at:, time_zone: "UTC").valid?
  end

  test "rejects bot and non-member organizers" do
    starts_at = 1.day.from_now

    assert_not @room.events.build(organizer: users(:bender), title: "Bot party", starts_at:, time_zone: "UTC").valid?

    outsider = User.create!(name: "Outsider", email_address: "outsider@example.test", password: "secret123456")
    assert_not @room.events.build(organizer: outsider, title: "Outsider party", starts_at:, time_zone: "UTC").valid?
  end

  test "records the organizer as going" do
    event = create_event!

    assert_equal "going", event.response_for(@organizer)
  end

  test "invites every other active human member" do
    event = create_event!

    %i[ jason jz kevin ].each do |name|
      item = ActivityItem.find_by!(user: users(name), source: event)
      assert_equal "event_invitation", item.event_type
      assert_predicate item, :unread?
    end
    assert_not ActivityItem.exists?(user: @organizer, source: event)
  end

  test "invitations exclude bots" do
    event = rooms(:watercooler).events.create!(
      organizer: @organizer, title: "Watercooler hang", starts_at: 1.day.from_now, time_zone: "UTC"
    )

    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: event).event_type
    assert_not ActivityItem.exists?(user: users(:bender), source: event)
  end

  test "a time change notifies going and maybe attendees without duplicating items" do
    event = create_event!
    event.attendances.create!(user: users(:jason), response: :going)
    event.attendances.create!(user: users(:jz), response: :maybe)
    event.attendances.create!(user: users(:kevin), response: :declined)

    event.update_with_announcement!({ starts_at: 3.days.from_now }, actor: @organizer)

    %i[ jason jz ].each do |name|
      items = ActivityItem.where(user: users(name), source: event)
      assert_equal 1, items.count
      assert_equal "event_update", items.first.event_type
      assert_predicate items.first, :unread?
    end

    kevin_item = ActivityItem.find_by!(user: users(:kevin), source: event)
    assert_equal "event_invitation", kevin_item.event_type
    assert_not ActivityItem.exists?(user: @organizer, source: event)
  end

  test "a time change resets the reminder" do
    event = create_event!(starts_at: 10.minutes.from_now)
    Event::ReminderDispatcher.dispatch_due!
    assert_not_nil event.reload.reminded_at

    event.update_with_announcement!({ starts_at: 2.days.from_now }, actor: @organizer)

    assert_nil event.reload.reminded_at
  end

  test "a title-only edit creates no items" do
    event = create_event!

    assert_no_difference -> { ActivityItem.where(source: event).count } do
      event.update_with_announcement!({ title: "Renamed" }, actor: @organizer)
    end
    assert_equal "Renamed", event.reload.title
  end

  test "cancel notifies going and maybe attendees and clears the other items" do
    event = create_event!
    event.attendances.create!(user: users(:jason), response: :going)
    event.attendances.create!(user: users(:jz), response: :maybe)
    event.attendances.create!(user: users(:kevin), response: :declined)

    assert event.cancel!(actor: @organizer)
    assert_predicate event.reload, :cancelled?

    %i[ jason jz ].each do |name|
      items = ActivityItem.where(user: users(name), source: event)
      assert_equal 1, items.count
      assert_equal "event_cancelled", items.first.event_type
      assert_predicate items.first, :unread?
    end

    assert_predicate ActivityItem.find_by!(user: users(:kevin), source: event), :handled?
  end

  test "cancelling twice is a no-op" do
    event = create_event!
    event.attendances.create!(user: users(:jason), response: :going)

    assert event.cancel!(actor: @organizer)
    cancelled_at = event.reload.cancelled_at

    assert_no_difference -> { ActivityItem.where(source: event).count } do
      assert_not event.cancel!(actor: @organizer)
    end
    assert_equal cancelled_at, event.reload.cancelled_at
  end

  test "event items vanish when the recipient leaves the room" do
    event = create_event!
    item = ActivityItem.find_by!(user: users(:jason), source: event)

    assert_includes ActivityItem.accessible_to(users(:jason)), item

    memberships(:jason_designers).destroy!

    assert_not ActivityItem.accessible_to(users(:jason)).exists?(item.id)
  end

  test "deleting a room removes its events, attendances, and inbox items" do
    event = create_event!
    attendance_ids = event.attendance_ids
    item_ids = ActivityItem.where(source: event).ids
    assert_not_empty item_ids

    @room.destroy!

    assert_empty Event.where(id: event.id)
    assert_empty EventAttendance.where(id: attendance_ids)
    assert_empty ActivityItem.where(id: item_ids)
  end

  private
    def create_event!(starts_at: 2.days.from_now, **attributes)
      @room.events.create!(
        organizer: @organizer, title: "Planning session", starts_at:, time_zone: "UTC", **attributes
      )
    end
end
