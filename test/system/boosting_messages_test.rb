require "application_system_test_case"

class BoostingMessagesTest < ApplicationSystemTestCase
  setup do
    # Existing free-text boosts keep their input alongside grouped reactions.
    messages(:third).boosts.create!(booster: users(:david), content: "Older note")
    sign_in "kevin@37signals.com"
    join_room rooms(:designers)
  end

  test "boosting a message" do
    within_message messages(:third) do
      fill_in_boost_input "Good morning"
      click_on "Submit"
      assert_boost_text "Good morning"
    end
  end

  test "deleting a boost" do
    using_session("David") do
      sign_in "david@37signals.com"
      join_room rooms(:designers)

      within "#" + dom_id(boosts(:first)) do
        find("span", text: "Hello").click
        assert_selector "button", text: "Delete this boost", wait: 5
        click_on "Delete this boost"
      end

      assert_no_text "Hello"
    end
  end

  test "message update preserves the input state" do
    within_message messages(:third) do
      assert_message_text "Third time's a charm."
      fill_in_boost_input "Hey!"
    end

    using_session("JZ") do
      sign_in "jz@37signals.com"
      join_room rooms(:designers)

      within_message messages(:third) do
        reveal_message_actions
        click_on "Edit message", exact: true
      end
      fill_in_markdown "Write a message", with: "Redacted!"
      click_on "Send Message"
      assert_message_text "Redacted!"
    end

    within_message messages(:third) do
      assert_message_text "Redacted!"
      assert_boost_input_value "Hey!"
    end
  end

  test "boost by another user preserves the input state" do
    within_message messages(:third) do
      assert_message_text "Third time's a charm."
      fill_in_boost_input "Hey!"
    end

    using_session("David") do
      sign_in "david@37signals.com"
      join_room rooms(:designers)

      within_message messages(:third) do
        fill_in_boost_input "Morning"
        click_on "Submit"
        assert_boost_text "Morning"
      end
    end

    perform_enqueued_jobs

    within_message messages(:third) do
      assert_boost_text "Morning"
      assert_boost_input_value "Hey!"
    end
  end

  private
    def fill_in_boost_input(text)
      click_on "Add a boost"
      fill_in "boost[content]", with: text
    end

    def assert_boost_input_value(text)
      assert page.has_field? "boost[content]", with: text
    end

    def assert_boost_text(text, **options)
      assert_selector ".boost", text: text, **options
    end
end
