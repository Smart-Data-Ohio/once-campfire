require "test_helper"

class Event::ReferenceSyncTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @event = events(:launch_party)
  end

  test "a message with an event link gains a reference" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-ref-1"
    )

    assert_equal [ @event ], message.events
    # The stored body is untouched: references live in the join table.
    assert_not_includes message.reload.markdown_source, "event-card"
  end

  test "absolute URLs on any host match" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see https://smartfire.example.test/rooms/999/events/#{@event.id}?x=1#frag",
      client_message_id: "evt-ref-absolute"
    )

    assert_equal [ @event ], message.events
  end

  test "duplicate URLs in one message create a single reference" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "/rooms/#{@room.id}/events/#{@event.id} and again /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-ref-dup"
    )

    assert_equal 1, message.event_references.count
  end

  test "a message without an event link references nothing" do
    message = @room.messages.create!(
      creator: users(:david), markdown_source: "just chatting", client_message_id: "evt-ref-none"
    )

    assert_empty message.events
  end

  test "a link to an event in another room creates nothing" do
    other_room = rooms(:pets)
    other_event = other_room.events.create!(
      organizer: users(:david), title: "Elsewhere", starts_at: 2.days.from_now, time_zone: "UTC"
    )
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{other_room.id}/events/#{other_event.id}",
      client_message_id: "evt-ref-other-room"
    )

    assert_empty message.events
    assert_empty message.event_references
  end

  test "a link to a missing event creates nothing" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/999999",
      client_message_id: "evt-ref-missing"
    )

    assert_empty message.events
    assert_empty message.event_references
  end

  test "editing a message to add an event link adds the reference" do
    message = @room.messages.create!(
      creator: users(:david), markdown_source: "just chatting", client_message_id: "evt-ref-edit"
    )
    assert_empty message.events

    message.update!(markdown_source: "now with /rooms/#{@room.id}/events/#{@event.id}")

    assert_equal [ @event ], message.reload.events
  end

  test "editing a message to remove an event link drops the reference" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-ref-remove"
    )
    assert_equal 1, message.event_references.count

    message.update!(markdown_source: "never mind")

    assert_empty message.reload.events
  end

  test "deleting the message removes its references" do
    message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "see /rooms/#{@room.id}/events/#{@event.id}",
      client_message_id: "evt-ref-msg-delete"
    )
    assert_equal 1, EventReference.where(message_id: message.id).count

    message.destroy!

    assert_empty EventReference.where(message_id: message.id)
    assert ::Event.exists?(@event.id)
  end
end
