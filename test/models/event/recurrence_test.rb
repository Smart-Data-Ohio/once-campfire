require "test_helper"

class Event::RecurrenceTest < ActiveSupport::TestCase
  include ActivityItemsHelper

  setup do
    @room = rooms(:designers)
    @organizer = users(:david)
  end

  test "daily generation advances calendar days and keeps the duration" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), ends_at: utc(2026, 10, 5, 10, 30),
      rule: "daily", until_date: Date.new(2026, 10, 7)
    )

    starts = head.series_events.map(&:starts_at)
    assert_equal [ utc(2026, 10, 5, 9, 0), utc(2026, 10, 6, 9, 0), utc(2026, 10, 7, 9, 0) ], starts
    head.series_events.each do |occurrence|
      assert_equal 90.minutes, occurrence.ends_at - occurrence.starts_at
    end
  end

  test "weekly generation advances seven days up to and including the end date" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )

    assert_equal [ Date.new(2026, 10, 5), Date.new(2026, 10, 12), Date.new(2026, 10, 19) ],
      head.series_events.map { |occurrence| occurrence.starts_at.to_date }
  end

  test "biweekly generation advances fourteen days" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "biweekly", until_date: Date.new(2026, 11, 2)
    )

    assert_equal [ Date.new(2026, 10, 5), Date.new(2026, 10, 19), Date.new(2026, 11, 2) ],
      head.series_events.map { |occurrence| occurrence.starts_at.to_date }
  end

  test "monthly generation anchors to the head day of month" do
    head = create_series!(
      starts_at: utc(2026, 10, 15, 9, 0), rule: "monthly", until_date: Date.new(2027, 1, 15)
    )

    assert_equal [ Date.new(2026, 10, 15), Date.new(2026, 11, 15), Date.new(2026, 12, 15), Date.new(2027, 1, 15) ],
      head.series_events.map { |occurrence| occurrence.starts_at.to_date }
  end

  test "monthly from the 31st falls back to the last day then returns to the 31st" do
    head = create_series!(
      starts_at: utc(2027, 1, 31, 10, 0), rule: "monthly", until_date: Date.new(2027, 4, 30)
    )

    assert_equal [ Date.new(2027, 1, 31), Date.new(2027, 2, 28), Date.new(2027, 3, 31), Date.new(2027, 4, 30) ],
      head.series_events.map { |occurrence| occurrence.starts_at.to_date }
    head.series_events.each do |occurrence|
      assert_equal 10, occurrence.starts_at.hour
    end
  end

  test "weekly across a daylight-saving change keeps the local wall-clock time" do
    zone = ActiveSupport::TimeZone["America/New_York"]
    head = create_series!(
      starts_at: zone.local(2026, 10, 25, 10, 0), time_zone: "America/New_York",
      rule: "weekly", until_date: Date.new(2026, 11, 15)
    )

    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size
    occurrences.each do |occurrence|
      assert_equal 10, occurrence.starts_at.in_time_zone("America/New_York").hour
    end
    assert_equal(-4.hours, occurrences.first.starts_at.in_time_zone("America/New_York").utc_offset)
    occurrences.drop(1).each do |occurrence|
      assert_equal(-5.hours, occurrence.starts_at.in_time_zone("America/New_York").utc_offset)
    end
  end

  test "materializing links every occurrence to the head and records the organizer as going" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)

    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size
    assert_equal head.id, head.series_id
    assert_predicate head, :series_head?
    occurrences.each do |occurrence|
      assert_equal head.id, occurrence.series_id
      assert_equal "weekly", occurrence.recurrence_rule
      assert_equal head.recurrence_until, occurrence.recurrence_until
      assert_equal "going", occurrence.response_for(@organizer)
    end
    assert_equal occurrences.drop(1).map(&:id), head.future_occurrences.ids
    assert_equal occurrences.second, occurrences.first.next_occurrence
    assert_equal occurrences.first, occurrences.second.previous_occurrence
    assert_nil occurrences.first.previous_occurrence
    assert_nil occurrences.third.next_occurrence
  end

  test "a single event has no series" do
    event = @room.events.create!(organizer: @organizer, title: "Single", starts_at: 2.days.from_now, time_zone: "UTC")

    assert_not event.series?
    assert_not event.series_head?
    assert_nil event.next_occurrence
    assert_nil event.previous_occurrence
    assert_empty event.future_occurrences
  end

  test "more than 52 occurrences is rejected with an earlier-end-date message" do
    event = @room.events.build(
      organizer: @organizer, title: "Too long", starts_at: utc(2026, 10, 1, 9, 0), time_zone: "UTC",
      recurrence_rule: "daily", recurrence_until: Date.new(2026, 12, 1)
    )

    assert_not event.valid?
    assert_match(/62 occurrences \(maximum 52\); pick an earlier end date/, event.errors[:recurrence_until].join)
    assert_no_difference -> { Event.count } do
      assert_raises(ActiveRecord::RecordInvalid) { event.save! }
    end
  end

  test "exactly 52 occurrences is allowed" do
    event = @room.events.build(
      organizer: @organizer, title: "Full year weekly", starts_at: utc(2026, 10, 1, 9, 0), time_zone: "UTC",
      recurrence_rule: "daily", recurrence_until: Date.new(2026, 10, 1) + 51.days
    )

    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "the occurrence cap and one-year range run on head updates too" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      head.update!(recurrence_until: 3.years.from_now.to_date)
    end
    assert_match(/at most one year/, error.record.errors[:recurrence_until].join)
    assert_equal Date.new(2026, 10, 19), head.reload.recurrence_until
  end

  test "the end date is required when a rule is set" do
    event = @room.events.build(
      organizer: @organizer, title: "No end", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "weekly"
    )

    assert_not event.valid?
    assert_equal [ "can't be blank" ], event.errors[:recurrence_until]
  end

  test "the end date must be after the start date" do
    starts_at = utc(2026, 10, 5, 9, 0)

    [ Date.new(2026, 10, 4), Date.new(2026, 10, 5) ].each do |until_date|
      event = @room.events.build(
        organizer: @organizer, title: "Bad end", starts_at:, time_zone: "UTC",
        recurrence_rule: "weekly", recurrence_until: until_date
      )

      assert_not event.valid?
      assert_equal [ "must be after the start date" ], event.errors[:recurrence_until]
    end
  end

  test "the end date must be at most one year after the start date" do
    starts_at = utc(2026, 10, 5, 9, 0)

    too_far = @room.events.build(
      organizer: @organizer, title: "Too far", starts_at:, time_zone: "UTC",
      recurrence_rule: "monthly", recurrence_until: Date.new(2027, 10, 6)
    )
    assert_not too_far.valid?
    assert_equal [ "must be at most one year after the start date" ], too_far.errors[:recurrence_until]

    just_inside = @room.events.build(
      organizer: @organizer, title: "One year", starts_at:, time_zone: "UTC",
      recurrence_rule: "monthly", recurrence_until: Date.new(2027, 10, 5)
    )
    assert just_inside.valid?, just_inside.errors.full_messages.to_sentence
  end

  test "unknown rules are rejected and blank rules normalize to nil" do
    event = @room.events.build(
      organizer: @organizer, title: "Bad rule", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "yearly", recurrence_until: Date.current + 30
    )
    assert_not event.valid?
    assert_includes event.errors[:recurrence_rule], "is not included in the list"

    single = @room.events.create!(
      organizer: @organizer, title: "Single", starts_at: 2.days.from_now, time_zone: "UTC", recurrence_rule: ""
    )
    assert_nil single.recurrence_rule
    assert_not single.series?
  end

  test "recurrence fields cannot be changed through plain update" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      head.update!(recurrence_rule: "daily")
    end
    assert_match(/first event/, error.record.errors[:recurrence_rule].join)
    assert_equal "weekly", head.reload.recurrence_rule

    assert_raises(ActiveRecord::RecordInvalid) do
      head.update!(series_id: nil)
    end
    assert_equal head.id, head.reload.series_id

    single = @room.events.create!(organizer: @organizer, title: "Single", starts_at: 2.days.from_now, time_zone: "UTC")
    error = assert_raises(ActiveRecord::RecordInvalid) do
      single.update!(recurrence_rule: "daily", recurrence_until: Date.current + 7)
    end
    assert_match(/scheduling a new event/, error.record.errors[:recurrence_rule].join)
    assert_nil single.reload.recurrence_rule
  end

  test "recurrence fields cannot be changed by injecting the guard flag" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )

    assert_raises(ActiveModel::UnknownAttributeError) do
      head.update!(allow_recurrence_mutation: true, recurrence_rule: "daily")
    end
    assert_equal "weekly", head.reload.recurrence_rule
  end

  test "the recurrence guard does not persist past a scoped update" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )
    head.update_with_scope!({ title: "Renamed" }, scope: "this_and_following", actor: @organizer)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      head.update!(recurrence_rule: "daily")
    end
    assert_match(/first event/, error.record.errors[:recurrence_rule].join)
    assert_equal "weekly", head.reload.recurrence_rule
  end

  test "a series sends one invitation per invitee, attached to the first event" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    %i[ jason jz kevin ].each do |name|
      items = ActivityItem.where(user: users(name), source: occurrences)
      assert_equal 1, items.count
      assert_equal head.id, items.first.source_id
      assert_equal "event_invitation", items.first.event_type
      assert_includes activity_item_event_body(items.first),
        "repeats weekly until #{head.recurrence_until.strftime("%B %-d, %Y")}"
    end
    assert_not ActivityItem.exists?(user: @organizer, source: occurrences)
  end

  test "a response on the first event is copied to every future occurrence" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    head.respond!(users(:jason), "going")

    occurrences.each do |occurrence|
      assert_equal "going", occurrence.response_for(users(:jason))
    end
  end

  test "a response on a later occurrence stays local without the checkbox" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    occurrences.second.respond!(users(:jason), "declined")

    assert_nil occurrences.first.response_for(users(:jason))
    assert_equal "declined", occurrences.second.response_for(users(:jason))
    assert_nil occurrences.third.response_for(users(:jason))
  end

  test "apply to all future copies the response to that occurrence and every later one" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 21)
    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size

    occurrences.second.respond!(users(:jason), "maybe", apply_to_future: true)

    assert_nil occurrences.first.response_for(users(:jason))
    occurrences.drop(1).each do |occurrence|
      assert_equal "maybe", occurrence.response_for(users(:jason))
    end
  end

  test "copying a response overwrites distinct later responses but skips cancelled occurrences" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.second.respond!(users(:jason), "declined")
    occurrences.third.cancel_with_scope!(scope: "this_event", actor: @organizer)

    head.respond!(users(:jason), "maybe")

    assert_equal "maybe", occurrences.first.response_for(users(:jason))
    assert_equal "maybe", occurrences.second.response_for(users(:jason))
    assert_equal "going", occurrences.third.response_for(users(:jason))
  end

  test "this event leaves its siblings untouched" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    occurrences.second.attendances.create!(user: users(:jason), response: :going)

    occurrences.second.update_with_scope!(
      {
        title: "Renamed",
        starts_at: occurrences.second.starts_at + 1.hour,
        ends_at: occurrences.second.ends_at + 1.hour
      },
      scope: "this_event", actor: @organizer
    )

    assert_equal "Renamed", occurrences.second.reload.title
    assert_equal "Planning session", occurrences.first.reload.title
    assert_equal "Planning session", occurrences.third.reload.title
    assert_equal utc_tomorrow_plus(0), occurrences.first.reload.starts_at
    assert_equal "event_update", ActivityItem.find_by!(user: users(:jason), source: occurrences.second).event_type
    assert_equal "event_invitation", ActivityItem.find_by!(user: users(:jason), source: occurrences.first).event_type
    assert_not ActivityItem.exists?(user: users(:jason), source: occurrences.third)
  end

  test "this event on the head accepts the form's unchanged rule values" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    occurrences.first.update_with_scope!(
      { title: "Renamed", recurrence_rule: "weekly", recurrence_until: head.recurrence_until.to_s },
      scope: "this_event", actor: @organizer
    )

    assert_equal "Renamed", occurrences.first.reload.title
    assert_equal "Planning session", occurrences.second.reload.title
    assert_equal "Planning session", occurrences.third.reload.title
  end

  test "this event is the default scope" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    occurrences.second.update_with_scope!({ title: "Renamed" }, scope: nil, actor: @organizer)

    assert_equal "Planning session", occurrences.first.reload.title
    assert_equal "Planning session", occurrences.third.reload.title
  end

  test "this and following shifts later occurrences by the same offset and copies the title" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 21)
    occurrences = head.series_events.to_a
    before = occurrences.map(&:starts_at)

    occurrences.second.update_with_scope!(
      { title: "Moved", starts_at: before.second + 1.hour, ends_at: occurrences.second.ends_at + 1.hour },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal before.first, occurrences.first.reload.starts_at
    assert_equal "Planning session", occurrences.first.title
    occurrences.drop(1).each_with_index do |occurrence, index|
      occurrence.reload
      assert_equal before[index + 1] + 1.hour, occurrence.starts_at
      assert_equal 1.hour, occurrence.ends_at - occurrence.starts_at
      assert_equal "Moved", occurrence.title
    end
  end

  test "moving an occurrence later shifts every original follower by the same offset" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size

    occurrences.second.update_with_scope!(
      { starts_at: utc(2027, 1, 20, 9, 0), ends_at: utc(2027, 1, 20, 10, 0) },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal utc(2027, 1, 1, 9, 0), occurrences.first.reload.starts_at
    assert_equal utc(2027, 1, 20, 9, 0), occurrences.second.reload.starts_at
    assert_equal utc(2027, 1, 27, 9, 0), occurrences.third.reload.starts_at
    assert_equal utc(2027, 2, 3, 9, 0), occurrences.fourth.reload.starts_at
  end

  test "moving an occurrence onto its head's slot is rejected in either scope" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrence = head.series_events.second

    %w[ this_event this_and_following ].each do |scope|
      error = assert_raises(ActiveRecord::RecordInvalid) do
        occurrence.update_with_scope!(
          { starts_at: utc(2027, 1, 1, 9, 0), ends_at: utc(2027, 1, 1, 10, 0) },
          scope:, actor: @organizer
        )
      end
      assert_equal [ "must stay between the neighbouring occurrences in its series" ], error.record.errors[:starts_at]
      assert_equal utc(2027, 1, 8, 9, 0), occurrence.reload.starts_at
    end
  end

  test "moving an occurrence before its previous sibling is rejected in either scope" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    before = head.series_events.map(&:starts_at)
    occurrence = head.series_events.second

    %w[ this_event this_and_following ].each do |scope|
      error = assert_raises(ActiveRecord::RecordInvalid) do
        occurrence.update_with_scope!(
          { starts_at: utc(2026, 12, 31, 9, 0), ends_at: utc(2026, 12, 31, 10, 0) },
          scope:, actor: @organizer
        )
      end
      assert_equal [ "must stay between the neighbouring occurrences in its series" ], error.record.errors[:starts_at]
    end

    assert_equal before, head.reload.series_events.map(&:starts_at)
  end

  test "a single-occurrence edit past the next sibling is rejected but this and following allows it" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrence = head.series_events.second

    error = assert_raises(ActiveRecord::RecordInvalid) do
      occurrence.update_with_scope!(
        { starts_at: utc(2027, 1, 16, 9, 0), ends_at: utc(2027, 1, 16, 10, 0) },
        scope: "this_event", actor: @organizer
      )
    end
    assert_equal [ "must stay between the neighbouring occurrences in its series" ], error.record.errors[:starts_at]
    assert_equal utc(2027, 1, 8, 9, 0), occurrence.reload.starts_at

    occurrence.update_with_scope!(
      { starts_at: utc(2027, 1, 16, 9, 0), ends_at: utc(2027, 1, 16, 10, 0) },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal [ utc(2027, 1, 1, 9, 0), utc(2027, 1, 16, 9, 0), utc(2027, 1, 23, 9, 0), utc(2027, 1, 30, 9, 0) ],
      head.reload.series_events.map(&:starts_at)
  end

  test "a re-time between the neighbouring occurrences still passes" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrence = head.series_events.second

    occurrence.update_with_scope!(
      { starts_at: utc(2027, 1, 9, 9, 0), ends_at: utc(2027, 1, 9, 10, 0) },
      scope: "this_event", actor: @organizer
    )

    assert_equal [ utc(2027, 1, 1, 9, 0), utc(2027, 1, 9, 9, 0), utc(2027, 1, 15, 9, 0), utc(2027, 1, 22, 9, 0) ],
      head.reload.series_events.map(&:starts_at)
  end

  test "moving an occurrence earlier with this and following never touches previous occurrences" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size

    occurrences.third.update_with_scope!(
      { starts_at: utc(2027, 1, 10, 9, 0), ends_at: utc(2027, 1, 10, 10, 0) },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal [ utc(2027, 1, 1, 9, 0), utc(2027, 1, 8, 9, 0), utc(2027, 1, 10, 9, 0), utc(2027, 1, 17, 9, 0) ],
      head.reload.series_events.map(&:starts_at)
  end

  test "this and following can shift an occurrence exactly onto the next active slot" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrence = head.series_events.second

    occurrence.update_with_scope!(
      { starts_at: utc(2027, 1, 15, 9, 0), ends_at: utc(2027, 1, 15, 10, 0) },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal [ utc(2027, 1, 1, 9, 0), utc(2027, 1, 15, 9, 0), utc(2027, 1, 22, 9, 0), utc(2027, 1, 29, 9, 0) ],
      head.reload.series_events.map(&:starts_at)
  end

  test "this and following can shift the head exactly onto the next active slot" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )

    head.update_with_scope!(
      { starts_at: utc(2027, 1, 8, 9, 0), ends_at: utc(2027, 1, 8, 10, 0) },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal [ utc(2027, 1, 8, 9, 0), utc(2027, 1, 15, 9, 0), utc(2027, 1, 22, 9, 0), utc(2027, 1, 29, 9, 0) ],
      head.reload.series_events.map(&:starts_at)
  end

  test "series slots are unique among uncancelled occurrences" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )

    index = ActiveRecord::Base.connection.indexes(:events).find { |candidate| candidate.name == "index_events_on_series_slot" }
    assert index, "expected the index_events_on_series_slot index to exist"
    assert index.unique

    taken = head.series_events.second
    assert_raises(ActiveRecord::RecordNotUnique) do
      @room.events.create!(
        organizer: @organizer, title: "Duplicate slot",
        starts_at: taken.starts_at, ends_at: taken.ends_at, time_zone: "UTC",
        series_id: head.id, recurrence_rule: "weekly", recurrence_until: head.recurrence_until
      )
    end
  end

  test "a starts-only change preserves later durations and an ends-only change extends them" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    occurrences.first.update_with_scope!(
      { starts_at: occurrences.first.starts_at - 1.hour }, scope: "this_and_following", actor: @organizer
    )

    occurrences.drop(1).each do |occurrence|
      occurrence.reload
      assert_equal 1.hour, occurrence.ends_at - occurrence.starts_at
    end

    occurrences.first.update_with_scope!(
      { ends_at: occurrences.first.reload.ends_at + 30.minutes }, scope: "this_and_following", actor: @organizer
    )

    occurrences.drop(1).each do |occurrence|
      assert_equal 90.minutes, occurrence.reload.ends_at - occurrence.starts_at
    end
  end

  test "a following time change sends one update per attendee and replaces earlier updates" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    head.respond!(users(:jz), "maybe")
    occurrences.second.update_with_scope!(
      {
        starts_at: occurrences.second.starts_at + 1.hour,
        ends_at: occurrences.second.ends_at + 1.hour
      },
      scope: "this_event", actor: @organizer
    )
    assert_equal "event_update", ActivityItem.find_by!(user: users(:jz), source: occurrences.second).event_type

    occurrences.first.update_with_scope!(
      {
        starts_at: occurrences.first.starts_at + 2.hours,
        ends_at: occurrences.first.ends_at + 2.hours
      },
      scope: "this_and_following", actor: @organizer
    )

    [ users(:jason), users(:jz) ].each do |attendee|
      items = ActivityItem.unread.where(user: attendee, source: occurrences)
      assert_equal 1, items.count
      assert_equal "event_update", items.first.event_type
      assert_equal occurrences.first.id, items.first.source_id
    end
    assert_predicate ActivityItem.find_by!(user: users(:jz), source: occurrences.second), :handled?
    assert_not ActivityItem.exists?(user: @organizer, source: occurrences)
  end

  test "a series update replaces read-but-unhandled updates on other occurrences" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.second.update_with_scope!(
      {
        starts_at: occurrences.second.starts_at + 1.hour,
        ends_at: occurrences.second.ends_at + 1.hour
      },
      scope: "this_event", actor: @organizer
    )
    item = ActivityItem.find_by!(user: users(:jason), source: occurrences.second)
    assert_equal "event_update", item.event_type
    item.mark_read!
    assert_predicate item.reload, :read?

    occurrences.first.update_with_scope!(
      {
        starts_at: occurrences.first.starts_at + 2.hours,
        ends_at: occurrences.first.ends_at + 2.hours
      },
      scope: "this_and_following", actor: @organizer
    )

    assert_predicate item.reload, :handled?
    unhandled = ActivityItem.where(user: users(:jason), source: occurrences, handled_at: nil)
    assert_equal 1, unhandled.count
    assert_equal "event_update", unhandled.first.event_type
    assert_equal occurrences.first.id, unhandled.first.source_id
  end

  test "a following title-only edit is silent but still copies the title" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")

    assert_no_difference -> { ActivityItem.where(user: users(:jason), source: occurrences).count } do
      occurrences.first.update_with_scope!({ title: "Renamed" }, scope: "this_and_following", actor: @organizer)
    end

    occurrences.each do |occurrence|
      assert_equal "Renamed", occurrence.reload.title
    end
  end

  test "rule changes are rejected away from the first event with this and following" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    error = assert_raises(ActiveRecord::RecordInvalid) do
      occurrences.second.update_with_scope!(
        { recurrence_rule: "daily" }, scope: "this_and_following", actor: @organizer
      )
    end
    assert_match(/first event/, error.record.errors[:recurrence_rule].join)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      occurrences.first.update_with_scope!(
        { recurrence_rule: "daily" }, scope: "this_event", actor: @organizer
      )
    end
    assert_match(/first event/, error.record.errors[:recurrence_rule].join)

    single = @room.events.create!(organizer: @organizer, title: "Single", starts_at: 2.days.from_now, time_zone: "UTC")
    error = assert_raises(ActiveRecord::RecordInvalid) do
      single.update_with_scope!({ recurrence_rule: "daily" }, scope: "this_event", actor: @organizer)
    end
    assert_match(/scheduling a new event/, error.record.errors[:recurrence_rule].join)
  end

  test "extending the end date reuses matching occurrences and copies responses to new ones" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")

    occurrences.first.update_with_scope!(
      { recurrence_until: Date.new(2026, 11, 2) }, scope: "this_and_following", actor: @organizer
    )

    current = head.reload.series_events.to_a
    assert_equal 5, current.size
    assert_equal occurrences.map(&:id), current.first(3).map(&:id)
    assert_equal [ Date.new(2026, 10, 26), Date.new(2026, 11, 2) ], current.last(2).map { |occurrence| occurrence.starts_at.to_date }
    current.last(2).each do |occurrence|
      assert_equal "going", occurrence.response_for(users(:jason))
      assert_equal "going", occurrence.response_for(@organizer)
    end
  end

  test "a rule change moves occurrences with distinct responses onto the new pattern's slots" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 26)
    )
    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size
    head.respond!(users(:jason), "going")
    occurrences.third.respond!(users(:jason), "declined")

    occurrences.first.update_with_scope!(
      { recurrence_rule: "daily", recurrence_until: Date.new(2026, 10, 6) },
      scope: "this_and_following", actor: @organizer
    )

    current = head.reload.series_events.to_a
    assert_equal 2, current.size
    moved = Event.find(occurrences.third.id)
    assert_equal utc(2026, 10, 6, 9, 0), moved.starts_at
    assert_equal utc(2026, 10, 6, 10, 0), moved.ends_at
    assert_equal "declined", moved.response_for(users(:jason))
    assert_equal "going", moved.response_for(@organizer)
    assert_not Event.exists?(occurrences.second.id)
    assert_not Event.exists?(occurrences.fourth.id)
    assert current.all? { |occurrence| occurrence.starts_at.to_date <= Date.new(2026, 10, 6) }
  end

  test "shortening weekly to daily cancels distinct occurrences beyond the new slots" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 26)
    )
    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size
    head.respond!(users(:jason), "going")
    occurrences.second.respond!(users(:jason), "declined")
    occurrences.third.respond!(users(:jz), "going")

    occurrences.first.update_with_scope!(
      { recurrence_rule: "daily", recurrence_until: Date.new(2026, 10, 6) },
      scope: "this_and_following", actor: @organizer
    )

    moved = Event.find(occurrences.second.id)
    assert_not_predicate moved, :cancelled?
    assert_equal utc(2026, 10, 6, 9, 0), moved.starts_at
    assert_equal "declined", moved.response_for(users(:jason))

    excess = Event.find(occurrences.third.id)
    assert_predicate excess, :cancelled?
    assert_equal "event_cancelled", ActivityItem.find_by!(user: users(:jason), source: excess).event_type
    assert_equal "event_cancelled", ActivityItem.find_by!(user: users(:jz), source: excess).event_type

    assert_equal [ head.id, moved.id ].sort, head.reload.series_events.active.ids.sort
    assert_not Event.exists?(occurrences.fourth.id)
  end

  test "a declined attendee gets no cancellation item when an excess occurrence is cancelled" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 26)
    )
    occurrences = head.series_events.to_a
    assert_equal 4, occurrences.size
    head.respond!(users(:jason), "going")
    occurrences.second.respond!(users(:jason), "declined")
    occurrences.third.respond!(users(:jz), "going")
    occurrences.third.respond!(users(:kevin), "declined")

    occurrences.first.update_with_scope!(
      { recurrence_rule: "daily", recurrence_until: Date.new(2026, 10, 6) },
      scope: "this_and_following", actor: @organizer
    )

    excess = Event.find(occurrences.third.id)
    assert_predicate excess, :cancelled?
    assert_equal "event_cancelled", ActivityItem.find_by!(user: users(:jz), source: excess).event_type
    assert_not ActivityItem.exists?(user: users(:kevin), source: excess, event_type: "event_cancelled")
  end

  test "a rule change with a time change re-times kept occurrences by the same offset" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.second.respond!(users(:jason), "declined")

    occurrences.first.update_with_scope!(
      {
        starts_at: utc(2026, 10, 5, 11, 0),
        ends_at: utc(2026, 10, 5, 12, 0),
        recurrence_until: Date.new(2026, 10, 20)
      },
      scope: "this_and_following", actor: @organizer
    )

    kept = Event.find(occurrences.second.id)
    assert_equal utc(2026, 10, 12, 11, 0), kept.starts_at
    assert_equal "declined", kept.response_for(users(:jason))
  end

  test "shrinking the series moves distinct occurrences onto the remaining slots and leaves cancelled ones" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 26)
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.fourth.respond!(users(:jason), "declined")
    occurrences.third.cancel_with_scope!(scope: "this_event", actor: @organizer)

    occurrences.first.update_with_scope!(
      { recurrence_until: Date.new(2026, 10, 12) }, scope: "this_and_following", actor: @organizer
    )

    moved = Event.find(occurrences.fourth.id)
    assert_not_predicate moved, :cancelled?
    assert_equal utc(2026, 10, 12, 9, 0), moved.starts_at
    assert_equal "declined", moved.response_for(users(:jason))
    assert_predicate Event.find(occurrences.third.id), :cancelled?
    assert_not Event.exists?(occurrences.second.id)
    assert_equal [ occurrences.first.id, occurrences.third.id, occurrences.fourth.id ].sort,
      head.reload.series_events.ids.sort
  end

  test "shrinking the series destroys regenerable occurrences beyond the new end" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 26)
    )
    occurrences = head.series_events.to_a

    occurrences.first.update_with_scope!(
      { recurrence_until: Date.new(2026, 10, 12) }, scope: "this_and_following", actor: @organizer
    )

    assert_equal [ occurrences.first.id, occurrences.second.id ], head.reload.series_events.ids
    assert_not Event.exists?(occurrences.third.id)
    assert_not Event.exists?(occurrences.fourth.id)
  end

  test "a cancelled occurrence keeps its slot when the series shrinks" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.third.respond!(users(:jason), "declined")
    occurrences.third.respond!(users(:jz), "going")
    occurrences.second.cancel_with_scope!(scope: "this_event", actor: @organizer)

    occurrences.first.update_with_scope!(
      { recurrence_until: Date.new(2026, 10, 12) }, scope: "this_and_following", actor: @organizer
    )

    kept = Event.find(occurrences.second.id)
    assert_predicate kept, :cancelled?
    assert_equal utc(2026, 10, 12, 9, 0), kept.starts_at

    excess = Event.find(occurrences.third.id)
    assert_predicate excess, :cancelled?
    assert_equal "event_cancelled", ActivityItem.find_by!(user: users(:jz), source: excess).event_type

    starts = head.reload.series_events.map(&:starts_at)
    assert_equal starts.uniq, starts
  end

  test "rematerialization can move a protected occurrence onto another planned mover's slot" do
    head = create_series!(
      starts_at: utc(2027, 1, 31, 10, 0), rule: "weekly", until_date: Date.new(2027, 3, 7)
    )
    occurrences = head.series_events.to_a
    assert_equal 6, occurrences.size
    protected_occurrence = occurrences.last
    assert_equal Date.new(2027, 3, 7), protected_occurrence.starts_at.to_date
    head.respond!(users(:jason), "going")
    protected_occurrence.respond!(users(:jason), "declined")

    head.update_with_scope!(
      { recurrence_rule: "monthly", recurrence_until: Date.new(2027, 7, 31) },
      scope: "this_and_following", actor: @organizer
    )

    current = head.reload.series_events.active.order(:starts_at).to_a
    assert_equal [
      Date.new(2027, 1, 31), Date.new(2027, 2, 28), Date.new(2027, 3, 31),
      Date.new(2027, 4, 30), Date.new(2027, 5, 31), Date.new(2027, 6, 30), Date.new(2027, 7, 31)
    ], current.map { |occurrence| occurrence.starts_at.to_date }
    assert_equal current.map(&:starts_at).uniq, current.map(&:starts_at)

    moved = Event.find(protected_occurrence.id)
    assert_equal utc(2027, 2, 28, 10, 0), moved.starts_at
    assert_equal "declined", moved.response_for(users(:jason))
    assert_equal "going", moved.response_for(@organizer)
  end

  test "a failure during rematerialization placement leaves every row with its original series and time" do
    head = create_series!(
      starts_at: utc(2027, 1, 31, 10, 0), rule: "weekly", until_date: Date.new(2027, 3, 7)
    )
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.last.respond!(users(:jason), "declined")
    before = occurrences.map { |occurrence| [ occurrence.series_id, occurrence.starts_at, occurrence.ends_at, occurrence.recurrence_rule ] }
    last_mover_id = occurrences.find { |occurrence| occurrence.starts_at == utc(2027, 2, 28, 10, 0) }.id

    failures = []
    with_failing_placement_for(last_mover_id, failures) do
      assert_raises(RuntimeError) do
        head.update_with_scope!(
          { recurrence_rule: "monthly", recurrence_until: Date.new(2027, 7, 31) },
          scope: "this_and_following", actor: @organizer
        )
      end
    end

    # The stub only fires while the row is parked (series_id cleared) and being
    # placed back into the series, so the failure happened inside
    # rematerialize_series! rather than during the earlier follower saves.
    assert_equal 1, failures.size
    assert_equal [ nil, head.id ], failures.first.series_id_change
    assert_not_equal utc(2027, 2, 28, 10, 0), failures.first.starts_at

    occurrences.each_with_index do |occurrence, index|
      fresh = Event.find(occurrence.id)
      assert_equal before[index][0], fresh.series_id
      assert_equal before[index][1], fresh.starts_at
      assert_equal before[index][2], fresh.ends_at
      assert_equal before[index][3], fresh.recurrence_rule
    end
    assert_equal 6, head.reload.series_events.count
    assert_not failures.first.instance_variable_get(:@allow_recurrence_mutation)
    assert_not failures.first.instance_variable_get(:@skip_series_order_validation)
  end

  test "series order puts uncancelled occurrences first at equal times" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 15)
    )
    occurrences = head.series_events.to_a
    occurrences.second.cancel_with_scope!(scope: "this_event", actor: @organizer)

    occurrences.third.update_with_scope!(
      { starts_at: utc(2027, 1, 8, 9, 0), ends_at: utc(2027, 1, 8, 10, 0) },
      scope: "this_event", actor: @organizer
    )

    current = head.reload.series_events.to_a
    assert_equal [ occurrences.first.id, occurrences.third.id, occurrences.second.id ], current.map(&:id)
    assert_equal occurrences.third.id, occurrences.first.next_occurrence.id
  end

  test "a rule change beyond the cap is rejected and leaves the series alone" do
    head = create_series!(
      starts_at: utc(2026, 10, 5, 9, 0), rule: "weekly", until_date: Date.new(2026, 10, 19)
    )
    before_ids = head.series_events.ids

    error = assert_raises(ActiveRecord::RecordInvalid) do
      head.update_with_scope!(
        { recurrence_rule: "daily", recurrence_until: Date.new(2026, 12, 15) },
        scope: "this_and_following", actor: @organizer
      )
    end
    assert_match(/pick an earlier end date/, error.record.errors[:recurrence_until].join)
    assert_equal before_ids, head.reload.series_events.ids
    assert_equal "weekly", head.recurrence_rule
  end

  test "cancelling this event touches only that occurrence" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    assert occurrences.second.cancel_with_scope!(scope: "this_event", actor: @organizer)

    assert_not_predicate occurrences.first.reload, :cancelled?
    assert_predicate occurrences.second.reload, :cancelled?
    assert_not_predicate occurrences.third.reload, :cancelled?
  end

  test "cancelling this and following sends one item per attendee on the earliest occurrence" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 21)
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")
    occurrences.third.respond!(users(:jz), "going")

    assert occurrences.second.cancel_with_scope!(scope: "this_and_following", actor: @organizer)

    assert_not_predicate occurrences.first.reload, :cancelled?
    assert_predicate occurrences.second.reload, :cancelled?
    assert_predicate occurrences.third.reload, :cancelled?
    assert_predicate occurrences.fourth.reload, :cancelled?

    [ users(:jason), users(:jz) ].each do |attendee|
      items = ActivityItem.where(user: attendee, source: occurrences, event_type: "event_cancelled")
      assert_equal 1, items.count
      assert_predicate items.first, :unread?
      assert_equal occurrences.second.id, items.first.source_id
    end
  end

  test "cancelling the series from the first event cancels every occurrence" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    head.respond!(users(:jason), "going")

    assert head.cancel_with_scope!(scope: "this_and_following", actor: @organizer)

    occurrences.each do |occurrence|
      assert_predicate occurrence.reload, :cancelled?
    end
    item = ActivityItem.find_by!(user: users(:jason), source: occurrences)
    assert_equal "event_cancelled", item.event_type
    assert_equal head.id, item.source_id
  end

  test "cancelling an already cancelled occurrence is a no-op" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a
    occurrences.second.cancel_with_scope!(scope: "this_event", actor: @organizer)

    assert_no_difference -> { ActivityItem.where(source: occurrences).count } do
      assert_not occurrences.second.cancel_with_scope!(scope: "this_and_following", actor: @organizer)
    end
    assert_not_predicate occurrences.third.reload, :cancelled?
  end

  test "cancel and update scopes default to this event for unknown values" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    occurrences.second.update_with_scope!({ title: "Renamed" }, scope: "bogus", actor: @organizer)
    assert_equal "Planning session", occurrences.third.reload.title

    occurrences.second.cancel_with_scope!(scope: "bogus", actor: @organizer)
    assert_not_predicate occurrences.third.reload, :cancelled?
  end

  test "a single-occurrence time edit of the head is rejected" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      head.update_with_scope!(
        { starts_at: utc(2027, 1, 1, 10, 0), ends_at: utc(2027, 1, 1, 11, 0) },
        scope: "this_event", actor: @organizer
      )
    end
    assert_equal [ "moves the whole series: choose This and following or the entire series" ], error.record.errors[:starts_at]
    assert_equal utc(2027, 1, 1, 9, 0), head.reload.starts_at
  end

  test "a head-only series can still be re-timed through this and following" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 5)
    )
    assert_equal [ head.id ], head.series_events.pluck(:id)

    head.update_with_scope!(
      { starts_at: utc(2027, 1, 1, 10, 0), ends_at: utc(2027, 1, 1, 11, 0) },
      scope: "this_and_following", actor: @organizer
    )

    assert_equal utc(2027, 1, 1, 10, 0), head.reload.starts_at
    assert_equal utc(2027, 1, 1, 11, 0), head.ends_at
    assert_equal head.id, head.series_id
    assert_equal [ head.id ], head.series_events.pluck(:id)
    assert_not head.instance_variable_get(:@following_reorder)
  end

  test "a single-occurrence description edit of the head still succeeds" do
    head = create_series!(rule: "weekly", until_date: Date.current + 1 + 14)
    occurrences = head.series_events.to_a

    head.update_with_scope!({ description: "Head note" }, scope: "this_event", actor: @organizer)

    assert_equal "Head note", head.reload.description
    assert_nil occurrences.second.reload.description
  end

  test "a plain update of the head start time is rejected" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      head.update!(starts_at: utc(2027, 1, 2, 9, 0))
    end
    assert_equal [ "moves the whole series: choose This and following or the entire series" ], error.record.errors[:starts_at]
    assert_equal utc(2027, 1, 1, 9, 0), head.reload.starts_at
  end

  test "a follower save failure clears the scoped flags and rolls the transaction back" do
    head = create_series!(
      starts_at: utc(2027, 1, 1, 9, 0), rule: "weekly", until_date: Date.new(2027, 1, 22)
    )
    occurrences = head.series_events.to_a
    editor = occurrences.second
    before = occurrences.map { |occurrence| [ occurrence.series_id, occurrence.starts_at, occurrence.ends_at ] }

    failures = []
    with_failing_save_for(occurrences.third.id, failures) do
      assert_raises(RuntimeError) do
        editor.update_with_scope!(
          { starts_at: utc(2027, 1, 9, 9, 0), ends_at: utc(2027, 1, 9, 10, 0) },
          scope: "this_and_following", actor: @organizer
        )
      end
    end

    assert_not editor.instance_variable_get(:@allow_recurrence_mutation)
    assert_not editor.instance_variable_get(:@following_reorder)
    assert_not editor.instance_variable_get(:@skip_series_order_validation)

    # The follower that raised is the instance the model loaded internally,
    # not one of the pre-loaded rows above; its flags must be cleared too.
    assert_equal 1, failures.size
    failing = failures.first
    assert_equal occurrences.third.id, failing.id
    assert_not_same occurrences.third, failing
    assert_not failing.instance_variable_get(:@allow_recurrence_mutation)
    assert_not failing.instance_variable_get(:@skip_series_order_validation)
    assert_not failing.instance_variable_get(:@following_reorder)

    occurrences.each_with_index do |occurrence, index|
      fresh = occurrence.reload
      assert_equal before[index][0], fresh.series_id
      assert_equal before[index][1], fresh.starts_at
      assert_equal before[index][2], fresh.ends_at
    end

    follower = occurrences.fourth
    assert_raises(RuntimeError) do
      follower.send(:with_series_follower_save) { raise "boom" }
    end
    assert_not follower.instance_variable_get(:@allow_recurrence_mutation)
    assert_not follower.instance_variable_get(:@skip_series_order_validation)

    assert_raises(RuntimeError) do
      follower.send(:with_following_reorder) { raise "boom" }
    end
    assert_not follower.instance_variable_get(:@following_reorder)
  end

  private
    def with_failing_save_for(event_id, failures = [])
      original = Event.instance_method(:save!)
      Event.define_method(:save!) do |*args, **kwargs, &block|
        if id == event_id
          failures << self
          raise "boom"
        end

        original.bind_call(self, *args, **kwargs, &block)
      end
      yield
    ensure
      Event.define_method(:save!, original)
    end

    # Fails only when the given row is being placed back into its series after
    # being parked (series_id cleared by with_parked_series_rows), which only
    # happens inside rematerialize_series!.
    def with_failing_placement_for(event_id, failures = [])
      original = Event.instance_method(:save!)
      Event.define_method(:save!) do |*args, **kwargs, &block|
        if id == event_id && series_id_was.nil? && series_id.present?
          failures << self
          raise "boom"
        end

        original.bind_call(self, *args, **kwargs, &block)
      end
      yield
    ensure
      Event.define_method(:save!, original)
    end
    def utc(year, month, day, hour, min = 0)
      ActiveSupport::TimeZone["UTC"].local(year, month, day, hour, min)
    end

    def utc_tomorrow_plus(days)
      utc(Date.current.year, Date.current.month, Date.current.day, 9, 0) + (1 + days).days
    end

    def create_series!(starts_at: utc_tomorrow_plus(0), ends_at: nil, time_zone: "UTC", rule:, until_date:)
      @room.events.create!(
        organizer: @organizer, title: "Planning session", starts_at:,
        ends_at: ends_at || starts_at + 1.hour, time_zone:,
        recurrence_rule: rule, recurrence_until: until_date
      )
    end
end
