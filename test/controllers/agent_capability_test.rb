require "test_helper"

class AgentCapabilityTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @secret = "bender-test-secret-1234"
  end

  test "legacy bot with no grants can still post and boost" do
    assert @agent.legacy_capabilities?

    assert_difference -> { Message.count }, +1 do
      post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
      assert_response :created
    end

    assert_difference -> { Boost.count }, +1 do
      post room_bot_message_boosts_url(@room, @bot.bot_key, messages(:fourth)), params: +"👀"
      assert_response :created
    end
  end

  test "agent with an active room grant can post and boost" do
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "react", room: @room)

    post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    assert_response :created

    post room_bot_message_boosts_url(@room, @bot.bot_key, messages(:fourth)), params: +"👀"
    assert_response :created
  end

  test "revoked post grant returns 403 with a JSON error immediately" do
    grant!(capability: "post_messages", room: @room).revoke!

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    end

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks post_messages capability", response.parsed_body["error"]
  end

  test "revoked react grant returns 403 on boost immediately" do
    grant!(capability: "react", room: @room).revoke!

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, messages(:fourth)), params: +"👀"
    end

    assert_response :forbidden
    assert_equal "Forbidden: agent lacks react capability", response.parsed_body["error"]
  end

  test "room grant for another room does not authorize posting" do
    grant!(capability: "post_messages", room: rooms(:designers))

    post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    assert_response :forbidden
  end

  test "workspace-wide grant does not bypass room membership" do
    grant!(capability: "post_messages")

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(rooms(:designers), @bot.bot_key), params: +"Hello!"
    end
    assert_response :not_found
  end

  test "suspended agent is forbidden from posting, even with legacy fallback" do
    @agent.suspend!

    post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    assert_response :forbidden
  end

  test "membership removal forbids the very next post" do
    grant!(capability: "post_messages", room: @room)
    memberships(:bender_watercooler).destroy!

    post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    assert_response :not_found
  end

  test "Bearer endpoint posts under the agent identity with a legacy fallback" do
    assert @agent.legacy_capabilities?

    assert_difference -> { Message.count }, +1 do
      post room_agent_messages_url(@room),
        params: { message: { body: "Hello from Bearer!", client_message_id: "bearer-legacy" } }.to_json,
        headers: bearer_headers
    end

    assert_response :created
    assert_equal "Hello from Bearer!", Message.last.plain_text_body
    assert_equal @bot, Message.last.creator
    assert_equal @bot.id, response.parsed_body.dig("creator", "id")
  end

  test "Bearer endpoint honors room grants and revocation immediately" do
    grant = grant!(capability: "post_messages", room: @room)

    post room_agent_messages_url(@room),
      params: { message: { body: "Granted", client_message_id: "bearer-granted" } }.to_json,
      headers: bearer_headers
    assert_response :created

    grant.revoke!

    post room_agent_messages_url(@room),
      params: { message: { body: "Revoked", client_message_id: "bearer-revoked" } }.to_json,
      headers: bearer_headers
    assert_response :forbidden
    assert_equal "Forbidden: agent lacks post_messages capability", response.parsed_body["error"]
  end

  test "Bearer endpoint does not bypass room membership" do
    grant!(capability: "post_messages")

    post room_agent_messages_url(rooms(:designers)),
      params: { message: { body: "Intruder", client_message_id: "bearer-intruder" } }.to_json,
      headers: bearer_headers
    assert_response :not_found
  end

  test "Bearer endpoint keeps 401 for authentication failures" do
    post room_agent_messages_url(@room),
      params: { message: { body: "Nope", client_message_id: "bearer-bad" } }.to_json,
      headers: { "Authorization" => "Bearer [REDACTED]", "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "Bearer endpoint denies session users and bot keys" do
    sign_in :david
    post room_agent_messages_url(@room),
      params: { message: { body: "Human", client_message_id: "bearer-human" } }
    assert_response :forbidden
    delete session_url

    post room_agent_messages_url(@room, bot_key: @bot.bot_key),
      params: { message: { body: "Legacy", client_message_id: "bearer-legacy-key" } }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
  end

  test "session-cookie POST gets 403 JSON with forgery protection enabled" do
    sign_in :david

    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post room_agent_messages_url(@room),
      params: { message: { body: "Human", client_message_id: "csrf-human" } }

    assert_response :forbidden
    assert_equal "Forbidden: Bearer agent token required", response.parsed_body["error"]
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  test "agent-token POST succeeds with forgery protection enabled" do
    original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post room_agent_messages_url(@room),
      params: { message: { body: "Hello", client_message_id: "csrf-bearer" } }.to_json,
      headers: bearer_headers

    assert_response :created
  ensure
    ActionController::Base.allow_forgery_protection = original_forgery_protection
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end
end
