require "test_helper"

class Github::PullRequestReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/12",
      client_message_id: "write-review-1"
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

  test "approve posts with the member's token, never the workspace token" do
    link_github!(users(:david), token: "user-token-abc")
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .with(body: { event: "APPROVE" }.to_json)
      .to_return(status: 200, body: { id: 2 }.to_json)

    assert_no_difference -> { Message.count } do
      post room_github_pull_request_reviews_url(@room),
        params: { pull_request_id: @pull_request.id, event: "APPROVE" }
    end

    assert_response :success
    assert_requested stub, headers: { "Authorization" => "Bearer user-token-abc" }
    assert_select ".github-pr-write__notice", text: "Approved on GitHub as @david."
  end

  test "request-changes posts the review body" do
    link_github!(users(:david))
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .with(body: { event: "REQUEST_CHANGES", body: "Fix the typo" }.to_json)
      .to_return(status: 200, body: { id: 3 }.to_json)

    post room_github_pull_request_reviews_url(@room),
      params: { pull_request_id: @pull_request.id, event: "REQUEST_CHANGES", body: "Fix the typo" }

    assert_response :success
    assert_requested stub
    assert_select ".github-pr-write__notice", text: "Requested changes on GitHub as @david."
  end

  test "request-changes without a body is rejected locally with 422" do
    link_github!(users(:david))

    post room_github_pull_request_reviews_url(@room),
      headers: { "Accept" => "text/vnd.turbo-stream.html" },
      params: { pull_request_id: @pull_request.id, event: "REQUEST_CHANGES", body: "  " }

    assert_response :unprocessable_content
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, "Add a note describing the requested changes."
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "an unknown event is rejected without calling GitHub" do
    link_github!(users(:david))

    post room_github_pull_request_reviews_url(@room),
      params: { pull_request_id: @pull_request.id, event: "COMMENT" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "Choose Approve or Request changes."
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "non-members get not found" do
    sign_in :kevin # not a member of the watercooler
    room = rooms(:watercooler)

    assert_raises(ActiveRecord::RecordNotFound) do
      post room_github_pull_request_reviews_url(room),
        params: { pull_request_id: @pull_request.id, event: "APPROVE" }
    end
  end

  test "a member without a linked token gets the connect prompt" do
    post room_github_pull_request_reviews_url(@room),
      params: { pull_request_id: @pull_request.id, event: "APPROVE" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__connect a[href=?]", user_profile_path, text: "Connect GitHub"
    assert_not_requested :post, %r{api\.github\.com}
  end

  test "a GitHub 403 renders inline with no retry" do
    link_github!(users(:david))
    stub = stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .to_return(status: 403, body: { message: "Pull request review is not permitted" }.to_json)

    post room_github_pull_request_reviews_url(@room),
      params: { pull_request_id: @pull_request.id, event: "APPROVE" }

    assert_response :unprocessable_content
    assert_select ".github-pr-write__error", text: "GitHub refused: Pull request review is not permitted"
    assert_requested stub, times: 1
  end

  test "a GitHub 401 disconnects the account and shows the reconnect prompt" do
    account = link_github!(users(:david))
    stub_request(:post, "https://api.github.com/repos/rails/rails/pulls/12/reviews")
      .to_return(status: 401, body: { message: "Bad credentials" }.to_json)

    post room_github_pull_request_reviews_url(@room),
      params: { pull_request_id: @pull_request.id, event: "APPROVE" }

    assert_response :unprocessable_content
    assert_not_predicate account.reload, :usable?
    assert_select ".github-pr-write__error", text: /GitHub rejected your token/
    assert_select ".github-pr-write__connect", text: /Reconnect GitHub/
  end

  private
    def link_github!(user, token: "user-token-abc")
      GithubConnectedAccount.create!(user:, github_login: user.name.parameterize, access_token: token)
    end
end
