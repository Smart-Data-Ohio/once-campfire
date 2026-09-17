require "application_system_test_case"

class EventsTest < ApplicationSystemTestCase
  test "scheduling an event invites members, who respond and see it in the inbox" do
    room = rooms(:designers)

    using_session("David") do
      sign_in "david@37signals.com"
      join_room room

      click_on "Events"
      assert_selector "h1", text: "Events"

      click_on "New event"
      fill_in "Title", with: "Launch retro"
      fill_in "Description (optional)", with: "Bring your notes."
      fill_in "Starts", with: 8.days.from_now.strftime("%Y-%m-%dT15:30")
      click_on "Schedule event"

      assert_selector "h1", text: "Launch retro"
      assert_text "Bring your notes."
      assert_text "Currently: Going"

      click_on "All events"
      assert_text "Launch retro"
    end

    event = Event.find_by!(title: "Launch retro")
    item = ActivityItem.find_by!(user: users(:jason), source: event, event_type: "event_invitation")

    using_session("Jason") do
      sign_in "jason@37signals.com"
      visit activity_items_url

      within "##{dom_id(item)}" do
        assert_text "Event invitation"
        assert_text "Launch retro"
      end

      open_inbox_item item, heading: "Launch retro"
      click_button "Going"
      assert_text "Currently: Going"
    end

    assert_equal "going", event.reload.response_for(users(:jason))
  end

  test "scheduling a repeating event invites once per member and copies the first response" do
    room = rooms(:designers)
    starts = 8.days.from_now

    using_session("David") do
      sign_in "david@37signals.com"
      join_room room

      click_on "Events"
      click_on "New event"
      fill_in "Title", with: "Weekly planning"
      # Chrome's locale date editing mangles ISO keystrokes, so the
      # datetime-local and date values are set directly in canonical format.
      page.execute_script(
        "document.getElementById('event_starts_at').value = #{starts.strftime("%Y-%m-%dT15:30").to_json}; " \
        "document.getElementById('event_recurrence_until').value = #{(starts + 14.days).strftime("%Y-%m-%d").to_json}"
      )
      select "Weekly", from: "Repeats"
      click_on "Schedule event"

      assert_selector "h1", text: "Weekly planning"
      assert_text "Part of a series"
      assert_text "Next occurrence"

      click_on "All events"
      assert_text "Repeats weekly"
      assert_text "3 occurrences remaining"
    end

    head = Event.where(title: "Weekly planning").order(:created_at).first
    occurrences = head.series_events.to_a
    assert_equal 3, occurrences.size
    assert_equal 1, ActivityItem.where(user: users(:jason), source: occurrences).count
    item = ActivityItem.find_by!(user: users(:jason), source: head, event_type: "event_invitation")

    using_session("Jason") do
      sign_in "jason@37signals.com"
      visit activity_items_url

      within "##{dom_id(item)}" do
        assert_text "Event invitation"
        assert_text "repeats weekly until"
      end

      open_inbox_item item, heading: "Weekly planning"
      click_button "Going"
      assert_text "Currently: Going"
    end

    occurrences.each do |occurrence|
      assert_equal "going", occurrence.response_for(users(:jason))
    end
  end

  private
    # The inbox re-renders its list when the activity channel connects, so a
    # click that lands on the item mid-replacement is retried, and the event
    # page gets more than the default wait to arrive on a loaded CI runner.
    def open_inbox_item(item, heading:)
      3.times do
        within("##{dom_id(item)}") { click_button "Open" }
        return if page.has_selector?("h1", text: heading, wait: 10)
      end

      assert_selector "h1", text: heading
    end
end
