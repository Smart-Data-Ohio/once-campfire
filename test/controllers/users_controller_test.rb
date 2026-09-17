require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @join_code = accounts(:signal).join_code
  end

  test "show" do
    sign_in :david
    get user_url(users(:david))
    assert_response :ok
  end

  test "bot profile links to capability grants for admins" do
    sign_in :david

    get user_url(users(:bender))

    assert_response :ok
    assert_select "a[href='#{account_bot_grants_path(users(:bender))}']", 1
  end

  test "bot profile links to capability grants for the agent owner" do
    agents(:bender_agent).update!(owner: users(:kevin))
    sign_in users(:kevin)

    get user_url(users(:bender))

    assert_response :ok
    assert_select "a[href='#{account_bot_grants_path(users(:bender))}']", 1
  end

  test "bot profile hides capability grants from anyone else" do
    sign_in users(:kevin)

    get user_url(users(:bender))

    assert_response :ok
    assert_select "a[href='#{account_bot_grants_path(users(:bender))}']", 0
  end

  test "new" do
    get join_url(@join_code)
    assert_response :success
  end

  test "new does not allow a signed in user" do
    sign_in :david

    get join_url(@join_code)
    assert_redirected_to root_url
  end

  test "new requires a join code" do
    get join_url("not")
    assert_response :not_found
  end

  test "create" do
    assert_difference -> { User.count }, 1 do
      post join_url(@join_code), params: { user: { name: "New Person", email_address: "new@37signals.com", password: "secret123456" } }
    end

    assert_redirected_to root_url

    user = User.last
    assert_equal user.id, Session.find_by(token: parsed_cookies.signed[:session_token]).user.id
    assert_equal Rooms::Open.all, user.rooms
  end

  test "creating a new user with an existing email address will redirect to login screen" do
    assert_no_difference -> { User.count } do
      post join_url(@join_code), params: { user: { name: "Another David", email_address: users(:david).email_address, password: "secret123456" } }
    end

    assert_redirected_to new_session_url(email_address: users(:david).email_address)
  end
end
