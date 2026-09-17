require "test_helper"

class Event::ReminderPusherTest < ActiveSupport::TestCase
  test "pushes the reminder to going and maybe attendees who are still members" do
    event = events(:launch_party)
    memberships(:jason_designers).destroy!

    pool = Rails.configuration.x.web_push_pool
    pool.expects(:queue).with do |payload, subscriptions|
      payload.fetch(:body) == "Starts in 15 minutes: Launch party planning" &&
        payload.fetch(:path) == Rails.application.routes.url_helpers.room_event_path(event.room, event) &&
        subscriptions.map(&:user_id) == [ users(:david).id ]
    end

    Event::ReminderPusher.new(event:).push
  end

  test "push reminders ignore the event_reminders inbox switch" do
    event = events(:launch_party)
    users(:david).update!(inbox_preferences: { "event_reminders" => false })

    pool = Rails.configuration.x.web_push_pool
    pool.expects(:queue).with do |_payload, subscriptions|
      subscriptions.map(&:user_id).include?(users(:david).id)
    end

    Event::ReminderPusher.new(event:).push
  end

  test "the push body names the venue" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])
    event = events(:launch_party)
    event.update!(venue_room_id: voice.id)

    pool = Rails.configuration.x.web_push_pool
    pool.expects(:queue).with do |payload, _subscriptions|
      payload.fetch(:body) == "Starts in 15 minutes: Launch party planning in Lounge"
    end

    Event::ReminderPusher.new(event:).push
  end

  test "a direct room reminder is titled by the organizer" do
    room = rooms(:david_and_jason)
    event = room.events.create!(
      organizer: users(:david), title: "Quick call", starts_at: 10.minutes.from_now, time_zone: "UTC"
    )
    event.attendances.create!(user: users(:jason), response: :going)

    pool = Rails.configuration.x.web_push_pool
    pool.expects(:queue).with do |payload, _subscriptions|
      payload.fetch(:title) == "David"
    end

    Event::ReminderPusher.new(event:).push
  end
end
