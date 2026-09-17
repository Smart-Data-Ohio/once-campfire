require "test_helper"

class Github::PullRequestReviewRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "write-review-request-1"
    )
    @pull_request = @message.github_pull_requests.first
    @thread = ChannelThread.create!(room: @room, creator: users(:david), parent_message: @message)
    ThreadMembership.join!(@thread, users(:david))
    Github::PullRequestThread.create!(pull_request: @pull_request, room: @room, channel_thread: @thread)

    @original_token = ENV["GITHUB_TOKEN"]
    ENV["GITHUB_TOKEN"] = "workspace-token"
  end

  teardown do
    ENV["GITHUB_TOKEN"] = @original_token
  end

  test "requests the review with the member's token, never the workspace token" do
    link_github!(users(:david), token: "user-token-abc")
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .with(body: { reviewers: [ "alice", "bob" ] }.to_json)
      .to_return(status: 201, body: { id: 12 }.to_json)

    assert_no_difference -> { Message.count } do
      post room_github_pull_request_review_requests_url(@room),
        params: { pull_request_id: @pull_request.id, reviewers: "alice, bob" }
    end

    assert_response :success
    assert_requested stub, headers: { "Authorization" => "Bearer user-token-abc" }
    assert_select "turbo-frame##{write_actions_dom_id}" do
      assert_select ".github-pr-write__notice", text: "Requested review from @alice, @bob on GitHub as @david."
      assert_select "form[action=?]", room_github_pull_request_review_requests_path(@room) do
        assert_select "input[name=reviewers][value]", count: 0
      end
    end
  end

  test "reviewers are split on commas or whitespace, stripped of @, downcased, and deduped" do
    link_github!(users(:david))
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .with(body: { reviewers: [ "alice", "bob" ] }.to_json)
      .to_return(status: 201, body: { id: 12 }.to_json)

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: " @Alice, alice  @BOB,bob " }

    assert_response :success
    assert_requested stub
    assert_select ".github-pr-write__notice", text: "Requested review from @alice, @bob on GitHub as @david."
  end

  test "success over Turbo Stream replaces the frame with the confirmation" do
    link_github!(users(:david))
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .to_return(status: 201, body: { id: 12 }.to_json)

    post room_github_pull_request_review_requests_url(@room),
      headers: { "Accept" => "text/vnd.turbo-stream.html" },
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, write_actions_dom_id
    assert_includes response.body, "Requested review from @alice"
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler
    room = rooms(:watercooler)

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_review_requests_url(room),
        params: { pull_request_id: @pull_request.id, reviewers: "alice" }
    end
  end

  test "a member without a linked token gets the connect prompt" do
    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__connect a[href=?]", user_profile_path, text: "Connect GitHub"
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a member with a disconnected token gets the reconnect prompt" do
    account = link_github!(users(:david))
    account.mark_disconnected!("GitHub rejected the linked token (401)")

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__connect", text: /Reconnect GitHub/
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a GitHub 403 renders inline with no retry" do
    link_github!(users(:david))
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)

    post room_github_pull_request_review_requests_url(@room),
      headers: { "Accept" => "text/vnd.turbo-stream.html" },
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :unprocessable_content
    assert_includes response.body, "GitHub refused: Resource not accessible by personal access token"
    assert_requested stub, times: 1
  end

  test "a GitHub 422 keeps the submitted reviewers and shows the message" do
    link_github!(users(:david))
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .to_return(status: 422, body: { message: "Review cannot be requested from pull request author" }.to_json)

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "GitHub refused: Review cannot be requested from pull request author"
    assert_select "form[action=?]", room_github_pull_request_review_requests_path(@room) do
      assert_select "input[name=reviewers][value=?]", "alice"
    end
  end

  test "a GitHub 401 disconnects the account and shows the reconnect prompt" do
    account = link_github!(users(:david))
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :unprocessable_content
    assert_not_predicate account.reload, :usable?
    assert_equal "GitHub rejected the linked token (401)", account.disconnected_reason
    assert_select ".github-pr-write__error", text: /GitHub rejected your token/
    assert_select ".github-pr-write__connect", text: /Reconnect GitHub/
  end

  test "invalid logins are rejected without calling GitHub and keep the input" do
    link_github!(users(:david))

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: "alice, bob!!" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "Enter GitHub usernames separated by commas."
    assert_select "form[action=?]", room_github_pull_request_review_requests_path(@room) do
      assert_select "input[name=reviewers][value=?]", "alice, bob!!"
    end
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "empty input is rejected without calling GitHub" do
    link_github!(users(:david))

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: "  " }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "Enter GitHub usernames separated by commas."
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "more than 15 reviewers are rejected without calling GitHub" do
    link_github!(users(:david))
    reviewers = (1..16).map { |index| "user#{index}" }.join(", ")

    post room_github_pull_request_review_requests_url(@room),
      params: { pull_request_id: @pull_request.id, reviewers: reviewers }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "Enter GitHub usernames separated by commas."
    assert_select "form[action=?]", room_github_pull_request_review_requests_path(@room) do
      assert_select "input[name=reviewers][value=?]", reviewers
    end
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a PR the room does not discuss gets not found" do
    link_github!(users(:david))
    other_pr = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 13)

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_review_requests_url(@room),
        params: { pull_request_id: other_pr.id, reviewers: "alice" }
    end
  end

  test "a bot key is forbidden, exactly as the comments endpoint" do
    delete session_url

    post room_github_pull_request_review_requests_url(@room, bot_key: users(:bender).bot_key),
      params: { pull_request_id: @pull_request.id, reviewers: "alice" }

    assert_response :forbidden
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "requesting never logs the member's token" do
    link_github!(users(:david), token: "user-token-secret-xyz")
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/requested_reviewers")
      .to_return(status: 201, body: { id: 12 }.to_json)

    log = StringIO.new
    with_captured_logs(log) do
      post room_github_pull_request_review_requests_url(@room),
        params: { pull_request_id: @pull_request.id, reviewers: "alice" }
    end

    assert_response :success
    assert_includes log.string, "pull_request_review_requests"
    assert_not_includes log.string, "user-token-secret-xyz"
  end

  private
    def link_github!(user, token: "user-token-abc")
      GithubConnectedAccount.create!(user:, github_login: user.name.parameterize, access_token: token)
    end

    def write_actions_dom_id
      ActionView::RecordIdentifier.dom_id(@thread, :github_write_actions)
    end

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
