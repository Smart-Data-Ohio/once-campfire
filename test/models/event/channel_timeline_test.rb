require "test_helper"

class Event::ChannelTimelineTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @room = rooms(:designers)
    @organizer = users(:david)
  end

  test "creating an event posts exactly one announcement by the organizer with the title and URL" do
    event = nil

    assert_difference -> { @room.root_messages.count }, 1 do
      event = @room.events.create!(
        organizer: @organizer, title: "Planning session", starts_at: 2.days.from_now, time_zone: "UTC"
      )
    end

    announcement = @room.root_messages.order(:created_at).last
    assert_equal @organizer, announcement.creator
    assert_equal "Scheduled an event: Planning session\n/rooms/#{@room.id}/events/#{event.id}",
      announcement.markdown_source
    assert_equal [ event ], announcement.events
  end

  test "a repeating series announces once for the head and occurrences never announce" do
    head = nil

    assert_difference -> { @room.root_messages.count }, 1 do
      head = @room.events.create!(
        organizer: @organizer, title: "Weekly planning", starts_at: 2.days.from_now, time_zone: "UTC",
        recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14
      )
    end

    occurrences = head.series_events.to_a
    assert_operator occurrences.size, :>, 1

    announcement = @room.root_messages.order(:created_at).last
    assert_equal "Scheduled an event: Weekly planning\n/rooms/#{@room.id}/events/#{head.id}",
      announcement.markdown_source
    assert_equal [ head ], announcement.events
    assert_empty EventReference.where(event_id: occurrences.map(&:id) - [ head.id ])
  end

  test "edits and cancellations post nothing" do
    event = create_event!

    assert_no_difference -> { Message.count } do
      event.update_with_announcement!({ title: "Renamed", starts_at: 3.days.from_now }, actor: @organizer)
      assert event.cancel!(actor: @organizer)
    end
  end

  test "the announcement creates no inbox items" do
    create_event!

    announcement = @room.root_messages.order(:created_at).last
    assert_empty ActivityItem.where(source: announcement)
  end

  test "updating an event broadcasts a card replace for each referencing message" do
    event = create_event!
    message = @room.messages.create!(
      creator: users(:jason),
      markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-broadcast-1"
    )
    other_room = rooms(:watercooler)
    other_message = other_room.messages.create!(
      creator: users(:jason),
      markdown_source: "also see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-broadcast-2"
    )
    assert_equal [ event ], message.events
    assert_equal [ event ], other_message.events

    # The announcement references the event too, so the room stream gets one
    # replace per referencing message in the room.
    room_stream = room_messages_stream_name(@room)
    other_stream = room_messages_stream_name(other_room)
    room_count = event.referencing_messages.where(room_id: @room.id).count
    other_count = event.referencing_messages.where(room_id: other_room.id).count
    assert_equal 2, room_count
    assert_equal 1, other_count

    assert_broadcasts room_stream, room_count do
      assert_broadcasts other_stream, other_count do
        event.update!(title: "A new title")
      end
    end
  end

  test "cancelling an event broadcasts card updates" do
    event = create_event!
    message = @room.messages.create!(
      creator: users(:jason),
      markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-broadcast-cancel"
    )
    assert_equal [ event ], message.events

    assert_broadcasts room_messages_stream_name(@room),
      event.referencing_messages.where(room_id: @room.id).count do
      assert event.cancel!(actor: @organizer)
    end
  end

  test "deleting the event removes its references" do
    event = create_event!
    message = @room.messages.create!(
      creator: users(:jason),
      markdown_source: "see /rooms/#{@room.id}/events/#{event.id}",
      client_message_id: "evt-ref-delete"
    )
    assert_not_empty EventReference.where(message_id: message.id, event_id: event.id)

    event.destroy!

    assert_empty EventReference.where(message_id: message.id, event_id: event.id)
    assert Message.exists?(message.id)
  end

  private
    def create_event!(**attributes)
      @room.events.create!(
        organizer: @organizer, title: "Planning session", starts_at: 2.days.from_now, time_zone: "UTC", **attributes
      )
    end

    def room_messages_stream_name(room)
      signed = Turbo::StreamsChannel.signed_stream_name([ room, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
end
