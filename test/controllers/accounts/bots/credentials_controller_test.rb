require "test_helper"

class Accounts::Bots::CredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @bot = users(:bender)
  end

  test "index lists credentials with last four only" do
    get account_bot_credentials_url(@bot)

    assert_response :ok
    assert_match "Main", response.body
    assert_match "1234", response.body
    assert_no_match "bender-test-secret-1234", response.body
  end

  test "create reveals the secret once" do
    assert_difference -> { AgentCredential.count }, +1 do
      post account_bot_credentials_url(@bot), params: {
        agent_credential: { name: "CI runner" }
      }
    end

    assert_response :created
    credential = AgentCredential.last
    assert_equal "CI runner", credential.name
    assert_equal users(:david), credential.created_by

    secret = response.body[/value="([^"]+)"/, 1]
    assert secret.present?
    assert_equal Digest::SHA256.hexdigest(secret), credential.token_digest
    assert_equal secret[-4..], credential.token_last_four
  end

  test "created secret authenticates on /agents/me but is never shown again" do
    post account_bot_credentials_url(@bot), params: {
      agent_credential: { name: "One-shot" }
    }

    secret = response.body[/value="([^"]+)"/, 1]
    delete session_url

    get agents_me_url, headers: { "Authorization" => "Bearer #{secret}" }
    assert_response :success

    sign_in :david
    get account_bot_credentials_url(@bot)
    assert_response :ok
    assert_no_match secret, response.body
  end

  test "create requires a name" do
    assert_no_difference -> { AgentCredential.count } do
      post account_bot_credentials_url(@bot), params: {
        agent_credential: { name: "" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "destroy revokes immediately and the token stops working" do
    credential = agent_credentials(:bender_main)

    delete account_bot_credential_url(@bot, credential)

    assert_redirected_to account_bot_credentials_url(@bot)
    assert credential.reload.revoked?
    delete session_url

    get agents_me_url, headers: { "Authorization" => "Bearer bender-test-secret-1234" }
    assert_response :unauthorized
  end

  test "index creates an agent for legacy bots missing one" do
    agents(:bender_agent).delete

    get account_bot_credentials_url(@bot)

    assert_response :ok
    assert @bot.reload.agent.present?
  end

  test "non-admins cannot manage credentials" do
    sign_in :kevin

    get account_bot_credentials_url(@bot)
    assert_response :forbidden
  end
end
