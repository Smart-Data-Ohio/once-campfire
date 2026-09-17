require "test_helper"

class Users::ProfilesControllerTest < ActionDispatch::IntegrationTest
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

  test "clearing a github login unlinks it" do
    users(:david).update!(github_login: "david-gh")

    put user_profile_url, params: { user: { github_login: "" } }

    assert_redirected_to user_profile_url
    assert_nil users(:david).reload.github_login
  end
end
