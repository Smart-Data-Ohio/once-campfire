require "test_helper"

class User::InboxPreferencesTest < ActiveSupport::TestCase
  test "every switch defaults to true for existing users" do
    preferences = users(:david).inbox_preferences

    User::InboxPreferences::KEYS.each do |key|
      assert_equal true, preferences[key], "expected #{key} to default to true"
      assert_equal true, preferences.public_send(key)
      assert_equal true, preferences.public_send("#{key}?")
    end
  end

  test "explicit false values persist and read back as false" do
    user = users(:david)
    user.update!(inbox_preferences: { "github_review_requests" => false, "huddle_invitations" => "0" })

    preferences = user.reload.inbox_preferences
    assert_equal false, preferences.github_review_requests
    assert_equal false, preferences.huddle_invitations
    assert_equal true, preferences.agent_approvals
    assert_equal true, preferences.agent_work
    assert_equal true, preferences.event_reminders
  end

  test "form values cast to booleans" do
    assert_equal true, User::InboxPreferences.cast("1")
    assert_equal true, User::InboxPreferences.cast("true")
    assert_equal false, User::InboxPreferences.cast("0")
    assert_equal false, User::InboxPreferences.cast("false")
    assert_equal true, User::InboxPreferences.cast(nil)
  end

  test "non-boolean input is rejected" do
    user = users(:david)
    user.inbox_preferences = { "github_review_requests" => "banana" }

    assert_not user.valid?
    assert_includes user.errors[:"inbox_preferences.github_review_requests"], "must be true or false"
    assert_equal true, user.reload.inbox_preferences.github_review_requests
  end

  test "assigning preferences merges into the existing hash" do
    user = users(:david)
    user.update!(inbox_preferences: { "github_review_requests" => false })
    user.update!(inbox_preferences: { "event_reminders" => false })

    preferences = user.reload.inbox_preferences
    assert_equal false, preferences.github_review_requests
    assert_equal false, preferences.event_reminders
    assert_equal true, preferences.agent_work
    assert_equal({ "github_review_requests" => false, "event_reminders" => false }, user.read_attribute(:inbox_preferences))
  end

  test "non-hash input is invalid without raising" do
    user = users(:david)
    user.inbox_preferences = "banana"

    assert_not user.valid?
    assert_includes user.errors[:inbox_preferences], "is invalid"
    assert_not user.update(inbox_preferences: "banana")
    assert_equal true, user.reload.inbox_preferences.github_review_requests
  end

  test "unknown keys are ignored" do
    user = users(:david)
    user.update!(inbox_preferences: { "bogus" => false })

    assert_equal({}, user.reload.read_attribute(:inbox_preferences))
    assert_equal true, user.inbox_preferences.github_review_requests
  end
end
