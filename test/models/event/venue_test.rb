require "test_helper"

class Event::VenueTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @organizer = users(:david)
    @voice = Rooms::Voice.create_for({ name: "Lounge", creator: @organizer }, users: [ @organizer, users(:jason) ])
    @stage = Rooms::Stage.create_for({ name: "Town Hall", creator: @organizer }, users: [ @organizer, users(:jason) ])
  end

  test "a venue is optional" do
    event = @room.events.build(organizer: @organizer, title: "No venue", starts_at: 2.days.from_now, time_zone: "UTC")

    assert event.valid?
    assert_nil event.venue
  end

  test "a voice or Stage channel venue is valid" do
    assert @room.events.build(organizer: @organizer, title: "Voice meetup",
      starts_at: 2.days.from_now, time_zone: "UTC", venue: @voice).valid?
    assert @room.events.build(organizer: @organizer, title: "Stage meetup",
      starts_at: 2.days.from_now, time_zone: "UTC", venue: @stage).valid?
  end

  test "a text channel or DM venue is rejected" do
    [ @room, rooms(:david_and_jason) ].each do |venue|
      event = @room.events.build(organizer: @organizer, title: "Bad venue",
        starts_at: 2.days.from_now, time_zone: "UTC", venue:)

      assert_not event.valid?
      assert_equal [ "must be a voice or Stage channel you belong to" ], event.errors[:venue]
    end
  end

  test "the organizer must belong to the venue" do
    outsiders = Rooms::Voice.create_for({ name: "Outsiders", creator: users(:jason) }, users: [ users(:jason) ])
    event = @room.events.build(organizer: @organizer, title: "Outsider meetup",
      starts_at: 2.days.from_now, time_zone: "UTC", venue: outsiders)

    assert_not event.valid?
    assert_equal [ "must be a voice or Stage channel you belong to" ], event.errors[:venue]
  end

  test "an event in a voice channel may use its own room as the venue" do
    event = @voice.events.build(organizer: @organizer, title: "Voice social",
      starts_at: 2.days.from_now, time_zone: "UTC", venue: @voice)

    assert event.valid?
  end

  test "other edits stay valid after the organizer leaves the venue" do
    event = create_event!(venue: @voice)
    @voice.memberships.find_by!(user: @organizer).destroy!

    assert_equal false, event.update_with_announcement!({ title: "Renamed" }, actor: @organizer)
    assert_equal "Renamed", event.reload.title
    assert_equal @voice.id, event.venue_room_id
  end

  test "deleting the venue clears the link but keeps the event" do
    event = create_event!(venue: @voice)

    @voice.destroy!

    assert_nil event.reload.venue_room_id
    assert_equal "Planning session", event.title
  end

  test "scheduling a series copies the venue to every occurrence" do
    head = create_series!(venue: @voice)

    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size
    occurrences.each do |occurrence|
      assert_equal @voice.id, occurrence.venue_room_id
    end
  end

  test "this and following propagates a venue change" do
    head = create_series!(venue: @voice)
    occurrences = head.series_events.to_a

    head.update_with_scope!({ venue_room_id: @stage.id }, scope: "this_and_following", actor: @organizer)

    occurrences.each do |occurrence|
      assert_equal @stage.id, occurrence.reload.venue_room_id
    end
  end

  test "this and following propagates clearing the venue" do
    head = create_series!(venue: @voice)
    occurrences = head.series_events.to_a

    head.update_with_scope!({ venue_room_id: nil }, scope: "this_and_following", actor: @organizer)

    occurrences.each do |occurrence|
      assert_nil occurrence.reload.venue_room_id
    end
  end

  test "a single-occurrence edit changes the venue for that occurrence only" do
    head = create_series!(venue: @voice)
    occurrences = head.series_events.to_a

    occurrences.second.update_with_scope!({ venue_room_id: @stage.id }, scope: "this_event", actor: @organizer)

    assert_equal @voice.id, occurrences.first.reload.venue_room_id
    assert_equal @stage.id, occurrences.second.reload.venue_room_id
    assert_equal @voice.id, occurrences.third.reload.venue_room_id
  end

  test "a venue-only edit creates no inbox items" do
    event = create_event!(venue: @voice)

    assert_no_difference -> { ActivityItem.where(source: event).count } do
      event.update_with_announcement!({ venue_room_id: @stage.id }, actor: @organizer)
    end
    assert_equal @stage.id, event.reload.venue_room_id
  end

  private
    def create_event!(**attributes)
      @room.events.create!(
        organizer: @organizer, title: "Planning session", starts_at: 2.days.from_now, time_zone: "UTC", **attributes
      )
    end

    def create_series!(starts_at: 2.days.from_now, **attributes)
      @room.events.create!(
        organizer: @organizer, title: "Weekly planning", starts_at:, time_zone: "UTC",
        recurrence_rule: "weekly", recurrence_until: Date.current + 2 + 14, **attributes
      )
    end
end
