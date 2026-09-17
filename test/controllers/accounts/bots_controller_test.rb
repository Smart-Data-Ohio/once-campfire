require "test_helper"

class Accounts::BotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index" do
    get account_bots_url
    assert_response :ok
  end

  test "index shows each bot's kind and owner" do
    get account_bots_url
    assert_response :ok
    assert_match "Workspace agent", response.body
    assert_match "Owned by David", response.body
  end

  test "index renders no owner recorded for ownerless agents" do
    agents(:bender_agent).update_columns(owner_id: nil)

    get account_bots_url
    assert_response :ok
    assert_match "no owner recorded", response.body
    assert_no_match "Owned by", response.body
  end

  test "index renders no owner recorded for bots without an agent" do
    agents(:bender_agent).delete

    get account_bots_url
    assert_response :ok
    assert_match "no owner recorded", response.body
  end

  test "create" do
    get new_account_bot_url
    assert_response :ok

    post account_bots_url, params: { user: { name: "Bender's Friend" } }
    assert_redirected_to account_bots_url
    assert_equal "Bender's Friend", User.bot.last.name

    agent = User.bot.last.agent
    assert agent.workspace?
    assert_equal users(:david), agent.owner
  end

  test "update" do
    get edit_account_bot_url(users(:bender))
    assert_response :ok

    put account_bot_url(users(:bender)), params: { user: { name: "Bender's New Friend" } }
    assert_redirected_to account_bots_url
    assert_equal "Bender's New Friend", users(:bender).reload.name
  end

  test "admin can set provider, runtime, and description" do
    get edit_account_bot_url(users(:bender))
    assert_response :ok
    assert_select "input[name='agent[provider]']", 1
    assert_select "input[name='agent[runtime]']", 1
    assert_select "textarea[name='agent[description]']", 1

    put account_bot_url(users(:bender)), params: {
      user: { name: "Bender Bot" },
      agent: { provider: "OpenAI", runtime: "Codex CLI 0.9", description: "Does things" }
    }

    assert_redirected_to account_bots_url
    assert_equal "OpenAI", agents(:bender_agent).reload.provider
    assert_equal "Codex CLI 0.9", agents(:bender_agent).runtime
    assert_equal "Does things", agents(:bender_agent).description
  end

  test "owner can set provider, runtime, and description" do
    agents(:bender_agent).update!(owner: users(:kevin))
    sign_in users(:kevin)

    get edit_account_bot_url(users(:bender))
    assert_response :ok
    assert_no_match "Manage agent credentials", response.body

    put account_bot_url(users(:bender)), params: {
      user: { name: "Bender Bot" },
      agent: { provider: "Anthropic", runtime: "Claude Code", description: "Helps out" }
    }

    assert_redirected_to account_bots_url
    assert_equal "Anthropic", agents(:bender_agent).reload.provider
  end

  test "another member gets 403 on edit and update" do
    sign_in users(:kevin)

    get edit_account_bot_url(users(:bender))
    assert_response :forbidden

    put account_bot_url(users(:bender)), params: {
      user: { name: "Bender Bot" }, agent: { provider: "Evil" }
    }
    assert_response :forbidden
    assert_nil agents(:bender_agent).reload.provider
  end

  test "owner still gets 403 on admin-only bot pages" do
    agents(:bender_agent).update!(owner: users(:kevin))
    sign_in users(:kevin)

    get account_bots_url
    assert_response :forbidden

    delete account_bot_url(users(:bender))
    assert_response :forbidden
  end

  test "description over 500 characters is rejected" do
    put account_bot_url(users(:bender)), params: {
      user: { name: "Bender Bot" }, agent: { description: "x" * 501 }
    }

    assert_response :unprocessable_entity
    assert_nil agents(:bender_agent).reload.description
  end

  test "destroy" do
    assert_difference -> { User.active_bots.count }, -1 do
      delete account_bot_url(users(:bender))
    end

    assert users(:bender).reload.deactivated?
  end

  test "remove webhook" do
    assert_difference -> { Webhook.count }, -1 do
      put account_bot_url(users(:bender)), params: { user: { name: "Bender's New Friend", webook_url: "" } }
      assert_redirected_to account_bots_url
    end
  end
end
