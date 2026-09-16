require "test_helper"

class AgentAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
  end

  test "GET /agents/me with a valid bearer token" do
    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :success
    json = response.parsed_body
    assert_equal @agent.id, json["id"]
    assert_equal "workspace", json["kind"]
    assert_equal "Bender Bot", json["name"]
    assert_equal users(:bender).id, json["user_id"]
    assert_equal users(:david).id, json.dig("owner", "id")

    assert agent_credentials(:bender_main).reload.last_used_at.present?
  end

  test "GET /agents/me with an invalid bearer token returns 401" do
    get agents_me_url, headers: { "Authorization" => "Bearer no-such-secret" }

    assert_response :unauthorized
  end

  test "GET /agents/me with a malformed authorization header redirects to login" do
    get agents_me_url, headers: { "Authorization" => "Token #{@secret}" }

    assert_redirected_to new_session_url
  end

  test "revoked credential returns 401 on the next request" do
    agent_credentials(:bender_main).revoke!

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :unauthorized
  end

  test "expired credential returns 401" do
    agent_credentials(:bender_main).update!(expires_at: 1.minute.ago)

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :unauthorized
  end

  test "suspended agent returns 401" do
    @agent.update!(suspended_at: Time.current)

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :unauthorized
  end

  test "deactivated bot user returns 401" do
    users(:bender).update!(status: :deactivated)

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :unauthorized
  end

  test "GET /agents/me without credentials redirects to login" do
    get agents_me_url

    assert_redirected_to new_session_url
  end

  test "GET /agents/me with a session for a bot user returns its agent" do
    sign_in users(:david)
    # David has no agent of his own, but can view Bender's agent via session fallback
    users(:david).create_agent!(kind: :personal, owner: users(:david))

    get agents_me_url

    assert_response :success
    assert_equal users(:david).agent.id, response.parsed_body["id"]
  end

  test "GET /agents/me with a session for a user without an agent returns 404" do
    sign_in :david

    get agents_me_url

    assert_response :not_found
  end

  test "bot keys remain denied on /agents/me" do
    get agents_me_url(bot_key: users(:bender).bot_key)

    assert_response :forbidden
  end

  test "agent tokens remain denied on regular HTML endpoints" do
    get room_url(rooms(:watercooler)), headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :forbidden
  end

  test "agent tokens skip CSRF protection like bot keys" do
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post room_messages_url(rooms(:watercooler)),
      params: { message: { body: "No token", client_message_id: "csrf-agent" } },
      headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :forbidden
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end
end
