require "test_helper"

class Calendar::SyncEntryJobTest < ActiveSupport::TestCase
  include GoogleCalendarTestHelper

  setup do
    @room = rooms(:designers)
    @event = events(:launch_party)
    @david = users(:david)
    @jason = users(:jason)

    @url_host_before_test = Rails.application.routes.default_url_options[:host]
    Rails.application.routes.default_url_options[:host] = "www.example.com"
  end

  teardown do
    if @url_host_before_test.nil?
      Rails.application.routes.default_url_options.delete(:host)
    else
      Rails.application.routes.default_url_options[:host] = @url_host_before_test
    end
  end

  test "going creates one Google event with the expected payload" do
    connect_google!(@david)
    insert = stub_google_event_insert

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    entry = EventCalendarEntry.find_by!(event: @event, user: @david)
    assert_equal Calendar::EntrySync.google_event_id_for(@event.id, @david.id), entry.google_event_id
    assert_not_nil entry.synced_at
    assert_nil entry.last_error
    assert_requested insert, times: 1
    assert_requested(:post, GOOGLE_EVENTS_URL) do |request|
      payload = JSON.parse(request.body)
      payload["id"] == entry.google_event_id &&
        payload["summary"] == "Launch party planning" &&
        payload["description"] == "Finalize the launch checklist.\n\nFrom Campfire: #{event_url}" &&
        payload["start"] == { "dateTime" => rfc3339(@event.starts_at), "timeZone" => "America/New_York" } &&
        payload["end"] == { "dateTime" => rfc3339(@event.ends_at), "timeZone" => "America/New_York" } &&
        payload["reminders"] == { "useDefault" => true } &&
        !payload.key?("attendees")
    end
  end

  test "events without an end default to one hour" do
    event = @room.events.create!(organizer: @david, title: "Quick sync", starts_at: 2.days.from_now, time_zone: "UTC")
    connect_google!(@david)
    stub_google_event_insert

    Calendar::SyncEntryJob.perform_now(event.id, @david.id)

    assert_requested(:post, GOOGLE_EVENTS_URL) do |request|
      JSON.parse(request.body)["end"] == {
        "dateTime" => rfc3339(event.starts_at + 1.hour, "UTC"), "timeZone" => "UTC"
      }
    end
  end

  test "changing to maybe keeps the entry" do
    connect_google!(@david)
    stub_google_event_insert
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    entry = EventCalendarEntry.find_by!(event: @event, user: @david)

    @event.attendances.find_by!(user: @david).update!(response: :maybe)
    update = stub_google_event_update(entry.google_event_id)

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested update
    assert EventCalendarEntry.exists?(entry.id)
  end

  test "declined deletes the entry" do
    connect_google!(@david)
    stub_google_event_insert
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    entry = EventCalendarEntry.find_by!(event: @event, user: @david)

    @event.attendances.find_by!(user: @david).update!(response: :declined)
    delete = stub_google_event_delete(entry.google_event_id)

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested delete
    assert_not EventCalendarEntry.exists?(entry.id)
  end

  test "an event time change patches the same id" do
    connect_google!(@david)
    stub_google_event_insert
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    entry = EventCalendarEntry.find_by!(event: @event, user: @david)

    @event.update!(starts_at: @event.starts_at + 30.minutes)
    update = stub_google_event_update(entry.google_event_id)

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested update
    assert_requested(:put, "#{GOOGLE_EVENTS_URL}/#{entry.google_event_id}") do |request|
      JSON.parse(request.body)["start"] == {
        "dateTime" => rfc3339(@event.reload.starts_at), "timeZone" => "America/New_York"
      }
    end
    assert EventCalendarEntry.exists?(entry.id)
  end

  test "cancellation deletes the entry" do
    connect_google!(@david)
    stub_google_event_insert
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    entry = EventCalendarEntry.find_by!(event: @event, user: @david)
    delete = stub_google_event_delete(entry.google_event_id)

    @event.update!(cancelled_at: Time.current)
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested delete
    assert_not EventCalendarEntry.exists?(entry.id)
  end

  test "leaving the room deletes the entry" do
    connect_google!(@david)
    stub_google_event_insert
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    entry = EventCalendarEntry.find_by!(event: @event, user: @david)
    delete = stub_google_event_delete(entry.google_event_id)

    memberships(:david_designers).destroy!
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested delete
    assert_not EventCalendarEntry.exists?(entry.id)
  end

  test "a user without a connection never triggers a request" do
    Calendar::SyncEntryJob.perform_now(@event.id, @jason.id)

    assert_no_google_requests
    assert_not EventCalendarEntry.exists?(event: @event, user: @jason)
  end

  test "a disconnected account never triggers a request" do
    connect_google!(@david, disconnected_reason: "Google rejected the connection")
    entry = EventCalendarEntry.create!(event: @event, user: @david, google_event_id: "stale" * 8)

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_no_google_requests
    assert_not EventCalendarEntry.exists?(entry.id)
  end

  test "an invalid_grant during sync disconnects and drops the local entry" do
    account = connect_google!(@david)
    account.update!(access_token_expires_at: 1.hour.ago)
    stub_google_token_invalid_grant

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_equal "Google rejected the connection", account.reload.disconnected_reason
    assert_not EventCalendarEntry.exists?(event: @event, user: @david)
  end

  test "two runs for the same state make no second insert" do
    connect_google!(@david)
    insert = stub_google_event_insert
    stub_google_event_update(Calendar::EntrySync.google_event_id_for(@event.id, @david.id))

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested insert, times: 1
    assert_equal 1, EventCalendarEntry.where(event: @event, user: @david).count
  end

  test "google event ids are deterministic per event and user and use Google's charset" do
    google_event_id = Calendar::EntrySync.google_event_id_for(@event.id, @david.id)

    assert_equal google_event_id, Calendar::EntrySync.google_event_id_for(@event.id, @david.id)
    assert_not_equal google_event_id, Calendar::EntrySync.google_event_id_for(@event.id, @jason.id)
    assert_not_equal google_event_id, Calendar::EntrySync.google_event_id_for(events(:watercooler_sync).id, @david.id)
    assert_match(/\A[a-v0-9]{5,1024}\z/, google_event_id)
  end

  test "concurrent first runs share one id and converge through the conflict path" do
    connect_google!(@david)
    google_event_id = Calendar::EntrySync.google_event_id_for(@event.id, @david.id)
    insert = stub_google_event_insert(status: 409, body: { "error" => { "code" => 409 } })
    update = stub_google_event_update(google_event_id)

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_equal 1, EventCalendarEntry.where(event: @event, user: @david).count
    assert_equal google_event_id, EventCalendarEntry.find_by!(event: @event, user: @david).google_event_id
    assert_requested insert, times: 1
    assert_requested update, times: 2
  end

  test "a 409 on insert falls back to updating the same id" do
    connect_google!(@david)
    stub_google_event_insert(status: 409, body: { "error" => { "code" => 409 } })
    stub_google_event_update(Calendar::EntrySync.google_event_id_for(@event.id, @david.id))

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    entry = EventCalendarEntry.find_by!(event: @event, user: @david)
    assert_requested :put, "#{GOOGLE_EVENTS_URL}/#{entry.google_event_id}"
    assert_not_nil entry.synced_at
    assert_nil entry.last_error
  end

  test "an update 404 falls back to inserting the same id" do
    connect_google!(@david)
    entry = EventCalendarEntry.create!(event: @event, user: @david,
      google_event_id: SecureRandom.hex(16), synced_at: 1.day.ago)
    stub_google_event_update(entry.google_event_id, status: 404)
    insert = stub_google_event_insert

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_requested insert
    assert_requested(:post, GOOGLE_EVENTS_URL) do |request|
      JSON.parse(request.body)["id"] == entry.google_event_id
    end
    assert_not_nil entry.reload.synced_at
  end

  test "delete treats a Google 404 as deleted" do
    connect_google!(@david)
    entry = EventCalendarEntry.create!(event: @event, user: @david, google_event_id: SecureRandom.hex(16))
    stub_google_event_delete(entry.google_event_id, status: 404)

    @event.attendances.find_by!(user: @david).update!(response: :declined)
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert_not EventCalendarEntry.exists?(entry.id)
  end

  test "a failed insert records last_error without raising" do
    connect_google!(@david)
    stub_google_event_insert(status: 500, body: { "error" => "backendError" })

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    entry = EventCalendarEntry.find_by!(event: @event, user: @david)
    assert_nil entry.synced_at
    assert_includes entry.last_error, "500"
  end

  test "a transport failure records an Unavailable last_error without raising" do
    connect_google!(@david)
    stub_request(:post, GOOGLE_EVENTS_URL).to_timeout

    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    entry = EventCalendarEntry.find_by!(event: @event, user: @david)
    assert_nil entry.synced_at
    assert_equal "Unavailable: Google Calendar request failed (Net::OpenTimeout)", entry.last_error
  end

  test "a failed delete keeps the row with last_error for a retry" do
    connect_google!(@david)
    entry = EventCalendarEntry.create!(event: @event, user: @david, google_event_id: SecureRandom.hex(16))
    stub_google_event_delete(entry.google_event_id, status: 500)

    @event.attendances.find_by!(user: @david).update!(response: :declined)
    Calendar::SyncEntryJob.perform_now(@event.id, @david.id)

    assert EventCalendarEntry.exists?(entry.id)
    assert_includes entry.reload.last_error, "500"
  end

  test "missing records are a no-op" do
    Calendar::SyncEntryJob.perform_now(0, @david.id)
    Calendar::SyncEntryJob.perform_now(@event.id, 0)

    assert_no_google_requests
  end

  test "responding going on the first event of a series syncs every occurrence" do
    connect_google!(@jason)
    head = @room.events.create!(
      organizer: @david, title: "Daily sync", starts_at: 2.days.from_now, time_zone: "UTC",
      recurrence_rule: "daily", recurrence_until: Date.current + 2 + 2
    )
    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size
    stub_google_event_insert

    assert_enqueued_jobs 3, only: Calendar::SyncEntryJob do
      head.respond!(@jason, "going")
    end

    perform_enqueued_jobs only: Calendar::SyncEntryJob

    assert_requested :post, GOOGLE_EVENTS_URL, times: 3
    google_ids = EventCalendarEntry.where(user: @jason, event: occurrences).pluck(:google_event_id)
    assert_equal 3, google_ids.size
    assert_equal 3, google_ids.uniq.size
  end

  test "creating an attendance enqueues a sync" do
    assert_enqueued_with(job: Calendar::SyncEntryJob, args: [ @event.id, users(:kevin).id ]) do
      @event.attendances.create!(user: users(:kevin), response: :going)
    end
  end

  test "changing a response enqueues a sync but other saves do not" do
    attendance = event_attendances(:launch_jason)

    assert_enqueued_with(job: Calendar::SyncEntryJob, args: [ @event.id, @jason.id ]) do
      attendance.update!(response: :declined)
    end

    assert_no_enqueued_jobs do
      attendance.update!(updated_at: 1.day.ago)
    end
  end

  test "updating event times enqueues syncs for connected going/maybe attendees" do
    connect_google!(@david)
    connect_google!(@jason, disconnected_reason: "Google rejected the connection")

    # jason is maybe but disconnected; jz declined without a connection.
    assert_enqueued_jobs 1, only: Calendar::SyncEntryJob do
      @event.update_with_announcement!({ starts_at: @event.starts_at + 30.minutes }, actor: @jason)
    end

    job = enqueued_jobs.find { |enqueued| enqueued[:job] == Calendar::SyncEntryJob }
    assert_equal [ @event.id, @david.id ], job[:args]
  end

  test "an update inside a transaction enqueues only after commit" do
    connect_google!(@david)

    Event.transaction do
      @event.update_with_announcement!({ title: "Launch party planning v2" }, actor: @david)
      assert_no_enqueued_jobs only: Calendar::SyncEntryJob
    end

    assert_enqueued_with(job: Calendar::SyncEntryJob, args: [ @event.id, @david.id ])
  end

  test "updating only the title enqueues a sync, an unchanged save does not" do
    connect_google!(@david)

    assert_enqueued_with(job: Calendar::SyncEntryJob, args: [ @event.id, @david.id ]) do
      @event.update_with_announcement!({ title: "Launch party planning v2" }, actor: @david)
    end

    assert_no_enqueued_jobs do
      @event.update_with_announcement!({ title: "Launch party planning v2" }, actor: @david)
    end
  end

  test "cancelling enqueues a sync for every entry" do
    EventCalendarEntry.create!(event: @event, user: @david, google_event_id: SecureRandom.hex(16))
    EventCalendarEntry.create!(event: @event, user: @jason, google_event_id: SecureRandom.hex(16))

    assert_enqueued_jobs 2, only: Calendar::SyncEntryJob do
      @event.cancel!(actor: @david)
    end
  end

  test "destroying a membership enqueues syncs for that room's entries only" do
    other_event = events(:watercooler_sync)
    EventCalendarEntry.create!(event: @event, user: @david, google_event_id: SecureRandom.hex(16))
    EventCalendarEntry.create!(event: other_event, user: @david, google_event_id: SecureRandom.hex(16))

    assert_enqueued_with(job: Calendar::SyncEntryJob, args: [ @event.id, @david.id ]) do
      memberships(:david_designers).destroy!
    end
  end

  private
    def rfc3339(time, zone = @event.time_zone)
      time.in_time_zone(zone).iso8601
    end

    def event_url
      Rails.application.routes.url_helpers.room_event_url(@room, @event, host: "www.example.com")
    end

    def assert_no_google_requests
      %i[ get post put patch delete ].each do |method|
        assert_not_requested method, %r{\Ahttps://[^/]*\.googleapis\.com/}
      end
    end
end
