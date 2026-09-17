require "test_helper"

class AgentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
  end

  test "PATCH /agents/me updates status and note for a valid Bearer [REDACTED]" do
    patch agents_me_url, params: { status: "working", status_note: "on it" },
      headers: { "Authorization" => "Bearer #{@secret}" }, as: :json

    assert_response :success
    assert_equal "working", response.parsed_body["status"]
    assert_equal "on it", response.parsed_body["status_note"]

    @agent.reload
    assert_equal "working", @agent.status
    assert_equal "on it", @agent.status_note
    assert @agent.status_changed_at.present?
  end

  test "PATCH /agents/me rejects an unknown status with 422 and a JSON error" do
    patch agents_me_url, params: { status: "napping" },
      headers: { "Authorization" => "Bearer #{@secret}" }, as: :json

    assert_response :unprocessable_entity
    assert response.parsed_body["error"].present?
    assert_equal "idle", @agent.reload.status
  end

  test "PATCH /agents/me ignores provider, runtime, and suspended_at in the body" do
    patch agents_me_url,
      params: { status: "working", provider: "Evil", runtime: "Evil", suspended_at: Time.current },
      headers: { "Authorization" => "Bearer #{@secret}" }, as: :json

    assert_response :success
    @agent.reload
    assert_equal "working", @agent.status
    assert_nil @agent.provider
    assert_nil @agent.runtime
    assert_nil @agent.suspended_at
  end

  test "PATCH /agents/me with a revoked credential returns 401" do
    agent_credentials(:bender_main).revoke!

    patch agents_me_url, params: { status: "working" },
      headers: { "Authorization" => "Bearer #{@secret}" }, as: :json

    assert_response :unauthorized
    assert_equal "idle", @agent.reload.status
  end

  test "PATCH /agents/me with a human session is forbidden" do
    sign_in :david

    patch agents_me_url, params: { status: "working" }, as: :json

    assert_response :forbidden
    assert_equal "idle", @agent.reload.status
  end

  test "PATCH /agents/me rejects an overlong note with 422" do
    patch agents_me_url, params: { status: "working", status_note: "x" * 201 },
      headers: { "Authorization" => "Bearer #{@secret}" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "idle", @agent.reload.status
  end

  test "GET /agents/me reflects the new status" do
    @agent.update!(status: "waiting", status_note: "need a human")

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :success
    assert_equal "waiting", response.parsed_body["status"]
    assert_equal "need a human", response.parsed_body["status_note"]
  end

  test "an authenticated request touches last_seen_at" do
    assert_nil @agent.last_seen_at

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_response :success
    assert @agent.reload.last_seen_at.present?
  end

  test "last_seen_at touches at most once per minute" do
    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }
    first_touch = @agent.reload.last_seen_at

    get agents_me_url, headers: { "Authorization" => "Bearer #{@secret}" }

    assert_equal first_touch, @agent.reload.last_seen_at
  end

  test "a rejected request does not touch last_seen_at" do
    get agents_me_url, headers: { "Authorization" => "Bearer [REDACTED]" }

    assert_response :unauthorized
    assert_nil @agent.reload.last_seen_at
  end
end
