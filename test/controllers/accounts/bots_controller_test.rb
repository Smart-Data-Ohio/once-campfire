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
