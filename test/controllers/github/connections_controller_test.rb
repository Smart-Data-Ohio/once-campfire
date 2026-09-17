require "test_helper"

class Github::ConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "linking validates the token with GET /user and stores the login" do
    stub = stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "Bearer github_pat_pasted" })
      .to_return(status: 200, body: { login: "octocat" }.to_json)

    post github_connection_url, params: { access_token: "github_pat_pasted" }

    assert_requested stub
    assert_redirected_to user_profile_path
    assert_equal "GitHub connected as octocat.", flash[:notice]

    account = users(:david).reload.github_connected_account
    assert_predicate account, :usable?
    assert_equal "octocat", account.github_login
    assert_equal "github_pat_pasted", account.access_token
  end

  test "linking sets the profile username when blank" do
    users(:david).update!(github_login: nil)
    stub_github_user("octocat")

    post github_connection_url, params: { access_token: "github_pat_pasted" }

    assert_equal "octocat", users(:david).reload.github_login
  end

  test "linking leaves the profile username and shows a mismatch notice when they differ" do
    users(:david).update!(github_login: "someone-else")
    stub_github_user("octocat")

    post github_connection_url, params: { access_token: "github_pat_pasted" }

    assert_equal "someone-else", users(:david).reload.github_login
    assert_match(/differs from your profile username/, flash[:notice])
  end

  test "linking leaves a taken login alone with an explanatory notice" do
    users(:david).update!(github_login: nil)
    users(:jz).update!(github_login: "octocat")
    stub_github_user("octocat")

    post github_connection_url, params: { access_token: "github_pat_pasted" }

    assert_nil users(:david).reload.github_login
    assert_match(/linked to another member/, flash[:notice])
    assert_equal "octocat", users(:david).github_connected_account.github_login
  end

  test "a rejected token stores nothing" do
    stub_request(:get, "https://api.github.com/user")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    assert_no_difference -> { GithubConnectedAccount.count } do
      post github_connection_url, params: { access_token: "bogus" }
    end

    assert_redirected_to user_profile_path
    assert_match(/rejected that token/, flash[:alert])
  end

  test "linking again after a disconnect replaces the token and clears the reason" do
    account = GithubConnectedAccount.create!(user: users(:david), github_login: "octocat", access_token: "old")
    account.mark_disconnected!("GitHub rejected the linked token (401)")
    stub_github_user("octocat")

    post github_connection_url, params: { access_token: "fresh-token" }

    assert_predicate account.reload, :usable?
    assert_equal "fresh-token", account.access_token
  end

  test "unlinking destroys the account" do
    GithubConnectedAccount.create!(user: users(:david), github_login: "octocat", access_token: "x")

    assert_difference -> { GithubConnectedAccount.count }, -1 do
      delete github_connection_url
    end

    assert_redirected_to user_profile_path
    assert_equal "GitHub disconnected.", flash[:notice]
  end

  test "profile shows link and unlink state without rendering the token" do
    get user_profile_url
    assert_response :success
    assert_select "form[action=?]", github_connection_path
    assert_select "input[type=password][name=access_token]"

    GithubConnectedAccount.create!(user: users(:david), github_login: "octocat", access_token: "super-secret-token")

    get user_profile_url
    assert_response :success
    assert_select "p", text: /Connected as octocat/
    assert_not_includes response.body, "super-secret-token"
  end

  test "linking never logs the pasted token" do
    stub_github_user("octocat")

    log = StringIO.new
    with_captured_logs(log) do
      post github_connection_url, params: { access_token: "github_pat_secret_xyz" }
    end

    assert_includes log.string, "github/connection"
    assert_not_includes log.string, "github_pat_secret_xyz"
  end

  test "the token parameter is filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    assert_equal "[FILTERED]", filter.filter(access_token: "github_pat_secret_xyz")[:access_token]
  end

  private
    def stub_github_user(login)
      stub_request(:get, "https://api.github.com/user")
        .to_return(status: 200, body: { login: login }.to_json)
    end

    # Swaps the Rails logger and the log subscribers' shared logger so the
    # request's Started/Processing/Parameters lines land in the capture.
    def with_captured_logs(io)
      capture = ActiveSupport::TaggedLogging.new(Logger.new(io))
      original_rails_logger = Rails.logger
      original_subscriber_logger = ActiveSupport::LogSubscriber.logger

      Rails.logger = capture
      ActiveSupport::LogSubscriber.logger = capture
      yield
    ensure
      Rails.logger = original_rails_logger
      ActiveSupport::LogSubscriber.logger = original_subscriber_logger
    end
end
