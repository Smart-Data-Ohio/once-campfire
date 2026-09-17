require "test_helper"

class Users::ProfilesControllerTest < ActionDispatch::IntegrationTest
  include GoogleCalendarTestHelper

  setup do
    sign_in :david
  end

  test "show" do
    get user_profile_url

    assert_response :success
  end

  test "update" do
    put user_profile_url, params: { user: { name: "John Doe", bio: "Acrobat" } }

    assert_redirected_to user_profile_url
    assert_equal "John Doe", users(:david).reload.name
    assert_equal "Acrobat", users(:david).bio
    assert_equal "david@37signals.com", users(:david).email_address
  end

  test "updates are limited to the current user" do
    put user_profile_url(users(:jason)), params: { user: { name: "John Doe" } }

    assert_equal "Jason", users(:jason).reload.name
  end

  test "profile shows Google Calendar as not configured without credentials" do
    disconnect_google_env!

    get user_profile_url

    assert_includes response.body, "Google Calendar is not configured for this workspace"
    assert_not_includes response.body, "Connect Google Calendar"
  end

  test "profile offers a connect button without an account" do
    get user_profile_url

    assert_includes response.body, "Connect Google Calendar"
  end

  test "profile shows the connected account with a disconnect button" do
    connect_google!(users(:david), email: "david@gmail.test")

    get user_profile_url

    assert_includes response.body, "Connected as david@gmail.test"
    assert_includes response.body, "Disconnect"
  end

  test "profile offers a reconnect when Google rejected the connection" do
    connect_google!(users(:david), disconnected_reason: "Google rejected the connection")

    get user_profile_url

    assert_includes response.body, "Google rejected the connection, reconnect"
    assert_includes response.body, "Connect Google Calendar"
  end

  test "profile offers Drive previews for a connected account without the Drive scope" do
    connect_google!(users(:david), email: "david@gmail.test")

    get user_profile_url

    assert_includes response.body, "Enable Drive previews"
    assert_not_includes response.body, "Drive previews enabled"
  end

  test "profile shows Drive previews as enabled when the account has the Drive scope" do
    connect_google!(users(:david), email: "david@gmail.test", scopes: DRIVE_SCOPES)

    get user_profile_url

    assert_includes response.body, "Drive previews enabled"
    assert_not_includes response.body, "Enable Drive previews"
  end

  test "profile shows no Drive row when Google is not configured" do
    disconnect_google_env!

    get user_profile_url

    assert_not_includes response.body, "Enable Drive previews"
    assert_not_includes response.body, "Drive previews enabled"
  end

  test "layout carries the Drive previews meta tag only with the Drive scope" do
    get user_profile_url
    assert_not_includes response.body, "google-drive-previews"

    connect_google!(users(:david), email: "david@gmail.test")
    get user_profile_url
    assert_not_includes response.body, "google-drive-previews"

    users(:david).google_account.update!(scopes: DRIVE_SCOPES)
    get user_profile_url
    assert_includes response.body, '<meta name="google-drive-previews" content="enabled">'
  end

  test "linking a github login strips and downcases it" do
    put user_profile_url, params: { user: { github_login: "  David-GH " } }

    assert_redirected_to user_profile_url
    assert_equal "david-gh", users(:david).reload.github_login
  end

  test "a github login cannot be claimed by a second user" do
    users(:jason).update!(github_login: "shared-login")

    put user_profile_url, params: { user: { github_login: "Shared-Login" } }

    assert_response :unprocessable_entity
    assert_select "p", text: /already linked to another user/
    assert_nil users(:david).reload.github_login
  end

  test "profile lists the notification switches with explanations" do
    get user_profile_url

    assert_response :success
    User::InboxPreferences::KEYS.each do |key|
      assert_select "input[name='user[inbox_preferences][#{key}]'][type=checkbox][checked]"
    end
    assert_includes response.body, "GitHub review requests"
    assert_includes response.body, "The incoming-call banner still shows."
  end

  test "profile saves the notification switches" do
    put user_profile_url, params: { user: { inbox_preferences: {
      "github_review_requests" => "0",
      "agent_approvals" => "0",
      "agent_work" => "1",
      "event_reminders" => "false",
      "huddle_invitations" => "true"
    } } }

    assert_redirected_to user_profile_url
    preferences = users(:david).reload.inbox_preferences
    assert_equal false, preferences.github_review_requests
    assert_equal false, preferences.agent_approvals
    assert_equal true, preferences.agent_work
    assert_equal false, preferences.event_reminders
    assert_equal true, preferences.huddle_invitations
  end

  test "profile rejects non-boolean notification input" do
    put user_profile_url, params: { user: { inbox_preferences: { "github_review_requests" => "banana" } } }

    assert_response :unprocessable_entity
    assert_equal true, users(:david).reload.inbox_preferences.github_review_requests
  end

  test "clearing a github login unlinks it" do
    users(:david).update!(github_login: "david-gh")

    put user_profile_url, params: { user: { github_login: "" } }

    assert_redirected_to user_profile_url
    assert_nil users(:david).reload.github_login
  end
end
