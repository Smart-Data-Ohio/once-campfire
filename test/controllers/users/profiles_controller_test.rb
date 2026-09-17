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
end
