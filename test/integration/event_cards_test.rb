require "test_helper"

class EventCardsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
  end

  test "a room member sees the card with title, time, venue, and organizer" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david), users(:jason) ])
    event = @room.events.create!(
      organizer: users(:david), title: "Planning session",
      starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour, time_zone: "UTC", venue: voice
    )
    message = @room.messages.create!(
      creator: users(:jason),
      markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-card-1"
    )

    get room_url(@room)

    assert_response :success
    # The scheduling announcement renders a card for the same event, so the
    # assertions scope to this message's cards container.
    assert_select "##{ActionView::RecordIdentifier.dom_id(message, :event_cards)}" do
      assert_select ".event-card", count: 1
      assert_select ".event-card__eyebrow", text: "Event"
      assert_select ".event-card__title", text: "Planning session"
      assert_select ".event-card__title a[href=?]", room_event_path(@room, event)
      assert_select ".event-card__meta time", count: 2
      assert_select ".event-card__venue", text: /Lounge/
      assert_select ".event-card__organizer", text: /David/
      assert_select "turbo-frame[src=?]",
        room_event_attendance_path(@room, event, message_id: message.id), count: 1
    end
  end

  test "the card shows no Join button and no live dot" do
    voice = Rooms::Voice.create_for({ name: "Lounge", creator: users(:david) }, users: [ users(:david) ])
    event = @room.events.create!(
      organizer: users(:david), title: "Venue meetup",
      starts_at: 2.days.from_now, time_zone: "UTC", venue: voice
    )
    @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-card-venue"
    )

    get room_url(@room)

    assert_response :success
    assert_select ".event-card", minimum: 1
    assert_select ".event-card", text: /Lounge/
    assert_select ".event-card a", text: "Join", count: 0
    assert_select ".event-card .sidebar-item__icon", count: 0
  end

  test "a repeating event shows the repeating eyebrow" do
    head = @room.events.create!(
      organizer: users(:david), title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
    )
    @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{head.id}",
      client_message_id: "evt-card-series"
    )

    get room_url(@room)

    assert_response :success
    assert_select ".event-card__eyebrow", text: "Repeating event"
  end

  test "a cancelled event shows the cancelled state" do
    event = @room.events.create!(
      organizer: users(:david), title: "Called off",
      starts_at: 2.days.from_now, time_zone: "UTC"
    )
    @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-card-cancelled"
    )
    event.cancel!(actor: users(:david))

    get room_url(@room)

    assert_response :success
    assert_select ".event-card--cancelled", minimum: 1
    assert_select ".event-card__state", text: "Cancelled"
  end

  test "the scheduling announcement renders its card in the room" do
    @room.events.create!(
      organizer: users(:david), title: "Announced session",
      starts_at: 2.days.from_now, time_zone: "UTC"
    )

    get room_url(@room)

    assert_response :success
    assert_select ".event-card__title", text: "Announced session"
  end

  test "a link to an event in another room stays a plain link with no card for anyone" do
    event_room = rooms(:pets) # david is a member; kevin is not
    event = event_room.events.create!(
      organizer: users(:david), title: "Secret planning",
      starts_at: 2.days.from_now, time_zone: "UTC"
    )
    event_url = "http://example.test/rooms/#{event_room.id}/events/#{event.id}"
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see #{event_url}",
      client_message_id: "evt-card-foreign"
    )
    assert_empty message.events

    # Even a member of both rooms gets no card: the fragment is cached and
    # broadcast across every viewer of the message's room, so the card only
    # ever renders for the room's own events.
    get room_url(@room)

    assert_response :success
    assert_select ".event-card", count: 0
    assert_select "a[href=?]", event_url, minimum: 1
    assert_not_includes response.body, "Secret planning"

    delete session_url
    sign_in :kevin # a designers member, but not a pets member

    get room_url(@room)

    assert_response :success
    assert_select ".event-card", count: 0
    assert_not_includes response.body, "Secret planning"
  end

  test "a message without an event link renders no card" do
    @room.messages.create!(
      creator: users(:david), markdown_source: "just chatting", client_message_id: "evt-card-none"
    )

    get room_url(@room)

    assert_response :success
    assert_select ".event-card", count: 0
  end

  test "rendering a room page costs no extra queries per message with an event link" do
    create_event_messages(2, offset: 0)

    get room_url(@room)
    assert_response :success

    small = count_queries { get room_url(@room) }
    assert_response :success

    create_event_messages(4, offset: 10)
    large = count_queries { get room_url(@room) }
    assert_response :success

    assert_equal small, large,
      "room render should be O(1) in queries, got #{small} then #{large}"
  end

  private
    def create_event_messages(count, offset:)
      count.times do |i|
        event = @room.events.create!(
          organizer: users(:david), title: "Query event #{offset + i}",
          starts_at: 2.days.from_now, time_zone: "UTC"
        )
        @room.messages.create!(
          creator: users(:david),
          markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
          client_message_id: "evt-card-query-#{offset + i}"
        )
      end
    end

    def count_queries
      count = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveRecord::Base.connection.clear_query_cache
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
end
