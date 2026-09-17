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
        click_button "Open"
      end

      assert_selector "h1", text: "Launch retro"
      click_button "Going"
      assert_text "Currently: Going"
    end

    assert_equal "going", event.reload.response_for(users(:jason))
  end
end
