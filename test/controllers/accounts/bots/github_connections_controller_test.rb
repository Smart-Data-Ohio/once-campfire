require "test_helper"

class Accounts::Bots::GithubConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @bot = users(:bender)
    @agent = agents(:bender_agent)
  end

  test "an administrator can link the agent's account" do
    token = "agent-pat-pasted"
    stub = stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "Bearer #{token}" })
      .to_return(status: 200, body: { login: "bender-machine" }.to_json)

    post account_bot_github_connection_url(@bot), params: { access_token: token }

    assert_requested stub
    assert_redirected_to edit_account_bot_url(@bot)
    assert_equal "GitHub connected as bender-machine.", flash[:notice]

    account = @bot.reload.github_connected_account
    assert_predicate account, :usable?
    assert_equal "bender-machine", account.github_login
    assert_equal token, account.access_token
  end

  test "the owner can link and unlink without admin rights" do
    @agent.update!(owner: users(:kevin))
    sign_in users(:kevin)
    stub_github_user("bender-machine")

    post account_bot_github_connection_url(@bot), params: { access_token: "owner-pat" }

    assert_redirected_to edit_account_bot_url(@bot)
    assert_predicate @bot.reload.github_connected_account, :usable?

    assert_difference -> { GithubConnectedAccount.count }, -1 do
      delete account_bot_github_connection_url(@bot)
    end

    assert_redirected_to edit_account_bot_url(@bot)
    assert_equal "GitHub disconnected.", flash[:notice]
  end

  test "another member gets 403 linking and unlinking" do
    GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "x")
    sign_in users(:kevin)

    post account_bot_github_connection_url(@bot), params: { access_token: "intruder-pat" }
    assert_response :forbidden

    delete account_bot_github_connection_url(@bot)
    assert_response :forbidden

    assert_predicate @bot.reload.github_connected_account, :usable?
    assert_not_requested :get, "https://api.github.com/user"
  end

  test "an administrator can unlink the agent's account" do
    GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "x")

    assert_difference -> { GithubConnectedAccount.count }, -1 do
      delete account_bot_github_connection_url(@bot)
    end

    assert_redirected_to edit_account_bot_url(@bot)
    assert_equal "GitHub disconnected.", flash[:notice]
  end

  test "a rejected token stores nothing and shows the GitHub message" do
    stub_request(:get, "https://api.github.com/user")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    assert_no_difference -> { GithubConnectedAccount.count } do
      post account_bot_github_connection_url(@bot), params: { access_token: "bogus" }
    end

    assert_redirected_to edit_account_bot_url(@bot)
    assert_match(/rejected that token/, flash[:alert])
  end

  test "an unreachable GitHub shows a retry message" do
    stub_request(:get, "https://api.github.com/user").to_timeout

    assert_no_difference -> { GithubConnectedAccount.count } do
      post account_bot_github_connection_url(@bot), params: { access_token: "any" }
    end

    assert_redirected_to edit_account_bot_url(@bot)
    assert_match(/Could not reach GitHub/, flash[:alert])
  end

  test "a blank token is rejected" do
    post account_bot_github_connection_url(@bot), params: { access_token: "  " }

    assert_redirected_to edit_account_bot_url(@bot)
    assert_match(/Paste a token/, flash[:alert])
    assert_not_requested :get, "https://api.github.com/user"
  end

  test "linking again after a disconnect replaces the token and clears the reason" do
    account = GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "old")
    account.mark_disconnected!("GitHub rejected the linked token (401)")
    stub_github_user("bender-machine")

    post account_bot_github_connection_url(@bot), params: { access_token: "fresh-token" }

    assert_predicate account.reload, :usable?
    assert_equal "fresh-token", account.access_token
  end

  test "the bot page shows the login without ever rendering the token" do
    get edit_account_bot_url(@bot)
    assert_response :success
    assert_select "form[action=?]", account_bot_github_connection_path(@bot)
    assert_select "input[type=password][name=access_token]"

    GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "super-secret-token")

    get edit_account_bot_url(@bot)
    assert_response :success
    assert_select "p", text: /Connected as bender-machine/
    assert_select "form[action=?]", account_bot_github_connection_path(@bot) do
      assert_select "input[type=password]", count: 0
    end
    assert_not_includes response.body, "super-secret-token"
  end

  test "deactivating the bot disconnects its GitHub account like a human's" do
    account = GithubConnectedAccount.create!(user: @bot, github_login: "bender-machine", access_token: "x")

    @bot.deactivate

    assert_equal "Account deactivated", account.reload.disconnected_reason
    assert_not_predicate account, :usable?
  end

  private
    def stub_github_user(login)
      stub_request(:get, "https://api.github.com/user")
        .to_return(status: 200, body: { login: login }.to_json)
    end
end
