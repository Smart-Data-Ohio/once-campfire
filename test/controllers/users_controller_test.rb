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

  test "bot profile shows agent identity, status, rooms, and grants to a member" do
    agents(:bender_agent).update!(
      provider: "OpenAI", runtime: "Codex CLI 0.9", description: "Does things",
      status: "working", status_note: "on it", status_changed_at: 2.hours.ago
    )
    sign_in users(:kevin)

    get user_url(users(:bender))

    assert_response :ok
    assert_select "h1", text: "Bender Bot"
    assert_match "Workspace agent, managed by David", response.body
    assert_match "OpenAI · Codex CLI 0.9", response.body
    assert_match "Does things", response.body
    assert_select ".agent-status-badge--working", text: "Working"
    assert_select ".agent-status-note", text: "on it"
    assert_match(/since .* ago/, response.body)
    assert_match "never", response.body
    assert_select "a[href='#{room_path(rooms(:bender_and_kevin))}']", 1
    assert_select "a[href='#{room_path(rooms(:watercooler))}']", 0
    assert_match "and 1 more", response.body
    assert_match "legacy access (no grants recorded)", response.body
  end

  test "bot profile shows the 24-hour activity line to the owner" do
    agent = agents(:bender_agent)
    agent.update!(owner: users(:kevin))
    message = rooms(:watercooler).messages.create!(creator: users(:david), body: "hey", client_message_id: "profile-activity")
    agent.agent_events.create!(event_type: "mention", room: rooms(:watercooler), message: message, outcome: "delivered")
    sign_in users(:kevin)

    get user_url(users(:bender))

    assert_response :ok
    assert_match "Last 24 hours: 1 delivered, 0 acknowledged, 0 posted, 0 suppressed", response.body
  end

  test "bot profile shows the 24-hour activity line to an admin" do
    agents(:bender_agent).update!(owner: users(:kevin))
    sign_in users(:david)

    get user_url(users(:bender))

    assert_response :ok
    assert_match "Last 24 hours:", response.body
  end

  test "bot profile hides the 24-hour activity line from another member" do
    sign_in users(:jz)

    get user_url(users(:bender))

    assert_response :ok
    assert_no_match "Last 24 hours:", response.body
  end

  test "bot profile hides rooms the viewer is not a member of" do
    sign_in users(:jz)

    get user_url(users(:bender))

    assert_response :ok
    assert_select "a[href='#{room_path(rooms(:watercooler))}']", 0
    assert_select "a[href='#{room_path(rooms(:bender_and_kevin))}']", 0
    assert_match "and 2 more", response.body
  end

  test "suspended agent profile shows Suspended" do
    agents(:bender_agent).suspend!
    sign_in users(:kevin)

    get user_url(users(:bender))

    assert_response :ok
    assert_select ".agent-status-badge--suspended", text: "Suspended"
  end

  test "bot without an agent keeps the minimal profile" do
    agents(:bender_agent).delete
    sign_in users(:kevin)

    get user_url(users(:bender))

    assert_response :ok
    assert_select "h1", text: "Bender Bot"
    assert_select ".agent-status", 0
    assert_no_match "Workspace agent", response.body
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
