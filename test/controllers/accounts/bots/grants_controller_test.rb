require "test_helper"

class Accounts::Bots::GrantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @bot = users(:bender)
    @agent = agents(:bender_agent)
  end

  test "index lists grants and the legacy notice" do
    get account_bot_grants_url(@bot)

    assert_response :ok
    assert_match "Legacy access", response.body
    assert_match "post_messages", response.body
  end

  test "index lists existing grants with scope and enforcement state" do
    AgentGrant.create!(agent: @agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages")
    AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "external_action")

    get account_bot_grants_url(@bot)

    assert_response :ok
    assert_match "All Talk", response.body
    assert_match "Workspace-wide", response.body
    assert_match "not yet enforced", response.body
    assert_no_match "Legacy access", response.body
  end

  test "room picker includes direct rooms under their display names" do
    direct_room = rooms(:bender_and_kevin)

    get account_bot_grants_url(@bot)

    assert_response :ok
    assert_select "select[name='agent_grant[room_id]'] option[value='#{direct_room.id}']", text: "Bender Bot and Kevin"
  end

  test "index renders a fallback for grants whose room was deleted" do
    AgentGrant.create!(agent: @agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages")
    rooms(:watercooler).destroy!

    get account_bot_grants_url(@bot)

    assert_response :ok
    assert_match "Deleted room", response.body
  end

  test "create grants a room capability" do
    assert_difference -> { AgentGrant.count }, +1 do
      post account_bot_grants_url(@bot), params: {
        agent_grant: { capability: "post_messages", room_id: rooms(:watercooler).id }
      }
    end

    assert_redirected_to account_bot_grants_url(@bot)
    grant = AgentGrant.last
    assert_equal @agent, grant.agent
    assert_equal rooms(:watercooler), grant.room
    assert_equal users(:david), grant.granted_by
    assert grant.active?
  end

  test "create with a blank room grants workspace-wide" do
    post account_bot_grants_url(@bot), params: {
      agent_grant: { capability: "react", room_id: "" }
    }

    assert_redirected_to account_bot_grants_url(@bot)
    assert AgentGrant.last.workspace_wide?
  end

  test "create rejects duplicates and unknown capabilities" do
    AgentGrant.create!(agent: @agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages")

    assert_no_difference -> { AgentGrant.count } do
      post account_bot_grants_url(@bot), params: {
        agent_grant: { capability: "post_messages", room_id: rooms(:watercooler).id }
      }
    end
    assert_response :unprocessable_entity

    assert_no_difference -> { AgentGrant.count } do
      post account_bot_grants_url(@bot), params: {
        agent_grant: { capability: "launch_missiles", room_id: "" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create reuses the existing grant when a concurrent create wins the race" do
    AgentGrant.create!(agent: @agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages")
    AgentGrant.any_instance.stubs(:save).raises(ActiveRecord::RecordNotUnique)

    assert_no_difference -> { AgentGrant.count } do
      post account_bot_grants_url(@bot), params: {
        agent_grant: { capability: "post_messages", room_id: rooms(:watercooler).id }
      }
    end

    assert_redirected_to account_bot_grants_url(@bot)
  end

  test "destroy revokes immediately and the next post is forbidden" do
    grant = AgentGrant.create!(agent: @agent, room: rooms(:watercooler), granted_by: users(:david), capability: "post_messages")

    delete account_bot_grant_url(@bot, grant)

    assert_redirected_to account_bot_grants_url(@bot)
    assert grant.reload.revoked?
    delete session_url

    post room_bot_messages_url(rooms(:watercooler), @bot.bot_key), params: +"Hello!"
    assert_response :forbidden
  end

  test "index creates an agent for legacy bots missing one" do
    @agent.delete

    get account_bot_grants_url(@bot)

    assert_response :ok
    assert @bot.reload.agent.present?
  end

  test "agent owner without admin rights can manage grants" do
    @agent.update!(owner: users(:kevin))
    sign_in users(:kevin)

    get account_bot_grants_url(@bot)
    assert_response :ok

    post account_bot_grants_url(@bot), params: {
      agent_grant: { capability: "post_messages", room_id: rooms(:watercooler).id }
    }
    assert_redirected_to account_bot_grants_url(@bot)

    delete account_bot_grant_url(@bot, AgentGrant.last)
    assert_redirected_to account_bot_grants_url(@bot)
    assert AgentGrant.last.revoked?
  end

  test "non-owner cannot manage grants" do
    sign_in users(:kevin)

    get account_bot_grants_url(@bot)
    assert_response :forbidden

    assert_no_difference -> { AgentGrant.count } do
      post account_bot_grants_url(@bot), params: {
        agent_grant: { capability: "post_messages", room_id: "" }
      }
    end
    assert_response :forbidden

    grant = AgentGrant.create!(agent: @agent, granted_by: users(:david), capability: "post_messages")
    delete account_bot_grant_url(@bot, grant)
    assert_response :forbidden
    assert_not grant.reload.revoked?
  end
end
