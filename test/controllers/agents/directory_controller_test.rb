require "test_helper"

class Agents::DirectoryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:bender_agent)
  end

  test "signed-in human sees every agent, active first" do
    suspended_bot = User.create_bot!(name: "Aaron Suspended")
    suspended_bot.create_agent!(kind: :workspace, owner: users(:david)).suspend!
    sign_in users(:kevin)

    get agents_url

    assert_response :ok
    assert response.body.index("Bender Bot") < response.body.index("Aaron Suspended"),
      "active agents must list before suspended ones"
    assert_match "Workspace agent, managed by David", response.body
    assert_select ".agent-status-badge--idle", text: "Idle"
    assert_select "a[href='#{user_path(users(:bender))}']", text: "Bender Bot"
  end

  test "directory row shows status note and last seen" do
    @agent.update!(status: "working", status_note: "on it", last_seen_at: 5.minutes.ago)
    sign_in users(:kevin)

    get agents_url

    assert_response :ok
    assert_select ".agent-status-note", text: "on it"
    assert_match(/last seen .* ago/, response.body)
  end

  test "deactivated agent users are absent" do
    users(:bender).deactivate
    sign_in users(:kevin)

    get agents_url

    assert_response :ok
    assert_no_match "Bender Bot", response.body
  end

  test "Bearer [REDACTED] request is forbidden" do
    get agents_url, headers: { "Authorization" => "Bearer bender-test-secret-1234" }

    assert_response :forbidden
  end

  test "legacy bot key request is forbidden" do
    get agents_url(bot_key: users(:bender).bot_key)

    assert_response :forbidden
  end

  test "unsigned-in request redirects to login" do
    get agents_url

    assert_redirected_to new_session_url
  end
end
