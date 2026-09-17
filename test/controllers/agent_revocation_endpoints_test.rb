require "test_helper"

# Endpoint-level proof that cascade revocation forbids the very next request.
# Each scenario exercises the legacy bot_key message endpoint, the legacy
# bot_key boost endpoint, and the Bearer agent endpoint.
class AgentRevocationEndpointsTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:watercooler)
    @bot = users(:bender)
    @agent = agents(:bender_agent)
    @message = messages(:fourth)
    @secret = "bender-test-secret-1234"
  end

  test "membership removal denies the next post, boost, and Bearer request" do
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "react", room: @room)
    memberships(:bender_watercooler).destroy!

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    end
    assert_response :not_found

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"👀"
    end
    assert_response :not_found

    assert_no_difference -> { Message.count } do
      post room_agent_messages_url(@room), params: bearer_params("revoke-membership"), headers: bearer_headers
    end
    assert_response :not_found
  end

  test "room deletion denies the next post, boost, and Bearer request" do
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "react", room: @room)
    message_id = @message.id
    @room.destroy!

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    end
    assert_response :not_found

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, message_id), params: +"👀"
    end
    assert_response :not_found

    assert_no_difference -> { Message.count } do
      post room_agent_messages_url(@room), params: bearer_params("revoke-room"), headers: bearer_headers
    end
    assert_response :not_found
  end

  test "agent suspension denies the next post, boost, and Bearer request" do
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "react", room: @room)
    @agent.suspend!

    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    end
    assert_response :forbidden

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"👀"
    end
    assert_response :forbidden

    # Suspended agents fail Bearer authentication itself, hence 401 rather
    # than the 403 the capability check would return.
    assert_no_difference -> { Message.count } do
      post room_agent_messages_url(@room), params: bearer_params("revoke-suspend"), headers: bearer_headers
    end
    assert_response :unauthorized
  end

  test "user deactivation denies the next post, boost, and Bearer request" do
    grant!(capability: "post_messages", room: @room)
    grant!(capability: "react", room: @room)
    @bot.deactivate

    # A deactivated bot no longer authenticates, so the legacy endpoints fall
    # through to the login redirect instead of creating anything.
    assert_no_difference -> { Message.count } do
      post room_bot_messages_url(@room, @bot.bot_key), params: +"Hello!"
    end
    assert_response :redirect

    assert_no_difference -> { Boost.count } do
      post room_bot_message_boosts_url(@room, @bot.bot_key, @message), params: +"👀"
    end
    assert_response :redirect

    assert_no_difference -> { Message.count } do
      post room_agent_messages_url(@room), params: bearer_params("revoke-deactivate"), headers: bearer_headers
    end
    assert_response :unauthorized
  end

  private
    def grant!(capability:, room: nil)
      AgentGrant.create!(agent: @agent, room: room, granted_by: users(:david), capability: capability)
    end

    def bearer_params(client_message_id)
      { message: { body: "Revoked?", client_message_id: client_message_id } }.to_json
    end

    def bearer_headers
      { "Authorization" => "Bearer #{@secret}", "Content-Type" => "application/json" }
    end
end
